#!/usr/bin/env bash
# dev-bringup.sh — Ensure the dev LKE cluster exists and is healthy.
# Called from the Woodpecker `ensure-dev-cluster` step on every PR and
# every push to main (#422). Idempotent:
#   - If the cluster already exists and is healthy (ingress LB IP
#     present): refresh kubeconfig, reconcile DNS, touch the heartbeat.
#   - If missing: run `manage_infra -e dev --phase1-dev-only` (skips the
#     local-state phase1 root — operator-managed always-up VMs are not
#     touched from CI) and `deploy_infra -e dev`, then touch the heartbeat.
#   - If the cluster exists but is degraded (no LB IP — pipeline #1333):
#     fall through to the cold path to repair, rather than failing loudly.
#
# Required env (set by ci/scripts/ci-deploy.sh after vault decrypt):
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY — for phase1-dev's S3 backend
#   LINODE_CLI_TOKEN                         — for cluster-existence check
#   DEV_STATE_BUCKET, DEV_STATE_S3_ENDPOINT, DEV_STATE_S3_KEY,
#   DEV_STATE_S3_SECRET                      — for the final heartbeat touch
#
# Plus everything `manage_infra` / `deploy_infra` themselves need
# (secrets.tfvars.env, kubeconfig path defaults to $REPO_ROOT/kubeconfig.dev.yaml).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

: "${LINODE_CLI_TOKEN:?LINODE_CLI_TOKEN is required (set in Woodpecker secrets)}"

CLUSTER_LABEL="${CLUSTER_LABEL:-matrix-cluster-dev}"

print_status "dev-bringup: checking for existing LKE cluster '$CLUSTER_LABEL'..."

# linode-cli reads token from LINODE_CLI_TOKEN env var (no config file needed).
# `--json` output keeps the parse robust against UI string changes.
EXISTING_ID=$(linode-cli lke clusters-list --json 2>/dev/null \
    | jq -r --arg label "$CLUSTER_LABEL" '.[] | select(.label==$label) | .id' \
    | head -n1 || true)

DID_PROVISION=false
CLUSTER_DEGRADED=false
if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
    print_success "dev-bringup: cluster exists (id=$EXISTING_ID); reusing"

    # The vault's kubeconfig can lag a real cluster recreation by an entire
    # operator vault-rebuild cycle. Pipeline #1262 surfaced this: a previous
    # pipeline recreated the cluster (new API endpoint) but failed mid-deploy,
    # so the next pipeline's kubectl calls hit the destroyed cluster's
    # endpoint and the bringup aborted before DNS reconcile. Fetch a fresh
    # kubeconfig from Linode for the current cluster id and write it to
    # $REPO_ROOT — mirrors dev-reaper.sh's pattern for the destroy side.
    #
    # Retry on transient API errors (pipeline #1330: `linode-cli` exited
    # nonzero with stderr swallowed by `2>/dev/null`, killing the script
    # under `set -euo pipefail` BEFORE the explicit error block ran). Now
    # we capture stderr to a tempfile and surface it on final failure.
    print_status "dev-bringup: fetching fresh kubeconfig for cluster id=$EXISTING_ID"
    KCFG_STDERR=$(mktemp)
    KCFG_RAW=$(mktemp)
    trap 'rm -f "$KCFG_STDERR" "$KCFG_RAW"' EXIT
    KCFG_B64=""
    KCFG_RC=1
    for _attempt in 1 2 3; do
        # Run linode-cli first and capture its rc directly. Don't pipe into jq
        # here — command substitution would put the pipe in a subshell, after
        # which PIPESTATUS in the parent shell reflects only the outer assign-
        # ment (always 0) and the diagnostic "rc=$KCFG_RC" would lie. Using
        # `&& KCFG_RC=0 || KCFG_RC=$?` keeps the test in a context where
        # `set -e` does not fire, so KCFG_RC accurately reflects linode-cli's
        # exit status.
        linode-cli lke kubeconfig-view --json "$EXISTING_ID" \
            >"$KCFG_RAW" 2>"$KCFG_STDERR" && KCFG_RC=0 || KCFG_RC=$?
        if [ "$KCFG_RC" -eq 0 ]; then
            KCFG_OUT=$(jq -r '.[0].kubeconfig // empty' "$KCFG_RAW" 2>/dev/null || true)
            if [ -n "$KCFG_OUT" ]; then
                KCFG_B64="$KCFG_OUT"
                break
            fi
        fi
        if [ "$_attempt" -lt 3 ]; then
            _backoff=$((_attempt * 5))
            print_warning "dev-bringup: linode-cli kubeconfig-view attempt $_attempt failed (rc=$KCFG_RC); retrying in ${_backoff}s"
            sleep "$_backoff"
        fi
    done
    if [ -z "$KCFG_B64" ]; then
        print_error "dev-bringup: could not fetch kubeconfig from Linode API after 3 attempts (rc=$KCFG_RC); aborting"
        print_error "dev-bringup: linode-cli stderr was:"
        sed 's/^/  /' "$KCFG_STDERR" >&2 || true
        exit 1
    fi
    rm -f "$KCFG_STDERR" "$KCFG_RAW"
    trap - EXIT
    umask 077
    echo "$KCFG_B64" | base64 -d > "$REPO_ROOT/kubeconfig.${MT_ENV:-dev}.yaml"
    umask 022
    export KUBECONFIG="$REPO_ROOT/kubeconfig.${MT_ENV:-dev}.yaml"
    print_status "dev-bringup: KUBECONFIG repointed to $KUBECONFIG (fresh from Linode)"

    # Stale-warm-cluster recovery (pipeline #1333): a cluster id exists and
    # the kubeconfig is fresh, but the cluster itself may be degraded — e.g.
    # ingress-nginx has no LB IP because deploy_infra never finished. Probe
    # the exact symptom that aborted #1333 (no LB IP on the ingress Service)
    # and if it's missing, treat the cluster as cold by falling through to
    # the provisioning branch below. Repair > fail-loud here: the issue
    # explicitly recommends falling through, and the operator's only
    # alternative (manual recovery) would just trigger this exact path.
    print_status "dev-bringup: probing ingress-nginx LB IP for warm-cluster health..."
    WARM_LB_IP=$(kubectl --kubeconfig="$KUBECONFIG" -n infra-ingress \
        get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -z "$WARM_LB_IP" ]; then
        print_warning "dev-bringup: cluster id=$EXISTING_ID exists but ingress-nginx has no LB IP"
        print_warning "dev-bringup: treating as cold; running phase1-dev + deploy_infra to repair"
        CLUSTER_DEGRADED=true
    else
        print_success "dev-bringup: warm cluster healthy (ingress LB IP=$WARM_LB_IP)"
    fi
fi

# Cold or degraded path: provision phase1-dev + deploy_infra. Reached either
# (a) when no cluster exists at all (post-reaper or first-run), or (b) when
# the warm-cluster health check above detected a degraded cluster (#1333).
if [ -z "$EXISTING_ID" ] || [ "$EXISTING_ID" = "null" ] || [ "$CLUSTER_DEGRADED" = "true" ]; then
    DID_PROVISION=true
    if [ "$CLUSTER_DEGRADED" = "true" ]; then
        print_status "dev-bringup: degraded warm cluster — re-running phase1-dev + deploy_infra to repair"
    else
        print_status "dev-bringup: no cluster found; provisioning..."
    fi

    # phase1-dev's S3 backend needs these env vars. Fail fast if missing —
    # the alternative (silent local backend fallback) would diverge from
    # operator state and is exactly the failure mode we built phase1-dev to
    # avoid.
    : "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required for phase1-dev backend (vault: tf-state-creds.env)}"
    : "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required for phase1-dev backend (vault: tf-state-creds.env)}"

    # manage_infra requires `secrets.tfvars.env` at the repo root for any
    # phase1 dispatch. phase1-dev only needs TF_VAR_linode_token; mirror
    # the reaper's behaviour in dev-reaper.sh which writes the same file
    # before invoking destroy. Pipeline #1247 surfaced this — the CI
    # bringup path had never been hit end-to-end before the first
    # post-reaper-destroy run.
    SECRETS_FILE="$REPO_ROOT/secrets.tfvars.env"
    umask 077
    cat > "$SECRETS_FILE" <<EOF
# CI bring-up generated; do not edit by hand.
export TF_VAR_linode_token="$LINODE_CLI_TOKEN"
EOF
    umask 022
    print_status "dev-bringup: wrote $SECRETS_FILE"

    # --phase1-dev-only: provision only the ephemeral phase1-dev (LKE
    # cluster + subnet). The local-state phase1 root holds
    # operator-managed always-up VMs (postgres-dev / headscale-dev /
    # turn-server-dev); CI doesn't have phase1's state and running
    # terraform there would try to recreate those VMs.
    # On the degraded path the cluster itself already exists, so terraform
    # finds it in state and no-ops; the value comes from deploy_infra
    # re-reconciling infra-* namespaces (ingress, certs, Keycloak, ...).
    print_status "dev-bringup: running manage_infra --phase1-dev-only..."
    "$REPO_ROOT/scripts/manage_infra" -e dev --phase1-dev-only

    # manage_infra wrote a fresh kubeconfig for the NEW cluster at
    # $REPO_ROOT/kubeconfig.dev.yaml (via the lke_cluster module's
    # local_file resource). The KUBECONFIG env var inherited from
    # ci-deploy.sh points at the vault's stale copy (the FRESH_KCFG check
    # in ci-deploy.sh ran BEFORE bringup, when no fresh file existed yet).
    # Repoint KUBECONFIG so deploy_infra talks to the cluster we just made.
    export KUBECONFIG="$REPO_ROOT/kubeconfig.${MT_ENV:-dev}.yaml"
    print_status "dev-bringup: KUBECONFIG repointed to $KUBECONFIG"

    print_status "dev-bringup: running deploy_infra..."
    "$REPO_ROOT/scripts/deploy_infra" -e dev

    print_success "dev-bringup: cluster + infra ready (DNS update follows)"
fi

# Always reconcile Cloudflare DNS for `lb1.dev.<base>` with the live ingress
# LB IP — runs on both the cold-start and reuse branches.
#
# Why unconditional: the cluster from a previous CI bringup persists across
# pipelines until the reaper destroys it, so most CI runs hit the "reuse"
# path. But every reaper cycle moves the LB to a new IP, and the deploy
# vault's kubeconfig (committed by the operator out-of-band) can lag the
# real DNS state. Pipeline #1254 surfaced this: cluster reused, DNS still
# pointed at a destroyed cluster's IP, every ingress-served gate hung.
# manage-dns.sh is idempotent — same IP is a no-op.
#
# Use the workspace kubeconfig if dev-bringup just provisioned (so we
# query the cluster manage_infra wrote a kubeconfig for), else trust the
# inherited KUBECONFIG from ci-deploy.sh (vault's copy).
if [ "$DID_PROVISION" = "true" ]; then
    export KUBECONFIG="$REPO_ROOT/kubeconfig.${MT_ENV:-dev}.yaml"
fi
NEW_LB_IP=$(kubectl --kubeconfig="$KUBECONFIG" -n infra-ingress \
    get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
if [ -z "$NEW_LB_IP" ]; then
    print_error "dev-bringup: could not read ingress LB IP; aborting"
    print_error "DNS may be stale (pointing at a destroyed cluster's IP)."
    exit 1
fi
# secrets.tfvars.env is required by manage_infra; write it if absent
# (reuse path doesn't run the cold-start block above).
if [ ! -f "$REPO_ROOT/secrets.tfvars.env" ]; then
    umask 077
    cat > "$REPO_ROOT/secrets.tfvars.env" <<EOF
# CI bring-up generated; do not edit by hand.
export TF_VAR_linode_token="$LINODE_CLI_TOKEN"
EOF
    umask 022
fi
print_status "dev-bringup: reconciling DNS lb1.dev.<base> → $NEW_LB_IP"
"$REPO_ROOT/scripts/manage_infra" -e dev --dns --lb-ip="$NEW_LB_IP"

# Always touch the heartbeat. The whole point of the on-demand-dev flow is
# that the reaper destroys the cluster when no CI step has touched it for
# IDLE_HOURS — so even on the "cluster already exists" path we want to push
# the timestamp forward.
print_status "dev-bringup: touching heartbeat"
"$REPO_ROOT/scripts/dev-heartbeat.sh"

print_success "dev-bringup: complete"
