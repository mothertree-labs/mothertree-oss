#!/usr/bin/env bash
# dev-bringup.sh — Ensure the dev LKE cluster exists. Called from the
# Woodpecker `ensure-dev-cluster` step on every PR. Idempotent:
#   - If the cluster already exists: noop apart from a heartbeat touch.
#   - If missing: run `manage_infra -e dev --phase1-dev-only` (skips the
#     local-state phase1 root — operator-managed always-up VMs are not
#     touched from CI) and `deploy_infra -e dev`, then touch the heartbeat.
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

if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
    print_success "dev-bringup: cluster exists (id=$EXISTING_ID); reusing"
else
    print_status "dev-bringup: no cluster found; provisioning..."

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

    # On cold start the dev cluster gets a brand-new ingress LoadBalancer
    # IP. Cloudflare DNS still points lb1.dev.<base> at the destroyed
    # cluster's IP, so every hostname behind ingress (auth, files, matrix,
    # …) is unreachable until DNS is updated. Pipeline #1253 surfaced this:
    # mt_wait_for_keycloak_oidc in deploy_infra timed out because it was
    # querying the OLD cluster's IP.
    #
    # manage_infra --dns → manage-dns.sh sources infra-config.sh on its
    # own (which exports TF_VAR_cloudflare_{api_token,zone_id} from the
    # infra-tenant secrets file). Pass --lb-ip explicitly so we don't race
    # with stale-cache lookups.
    NEW_LB_IP=$(kubectl --kubeconfig="$KUBECONFIG" -n infra-ingress \
        get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -z "$NEW_LB_IP" ]; then
        print_error "dev-bringup: could not read new ingress LB IP; aborting"
        print_error "DNS would otherwise stay pointed at the destroyed cluster's IP."
        exit 1
    fi
    print_status "dev-bringup: running manage_infra --dns --lb-ip=$NEW_LB_IP"
    "$REPO_ROOT/scripts/manage_infra" -e dev --dns --lb-ip="$NEW_LB_IP"

    print_success "dev-bringup: cluster + infra + DNS ready"
fi

# Always touch the heartbeat. The whole point of the on-demand-dev flow is
# that the reaper destroys the cluster when no CI step has touched it for
# IDLE_HOURS — so even on the "cluster already exists" path we want to push
# the timestamp forward.
print_status "dev-bringup: touching heartbeat"
"$REPO_ROOT/scripts/dev-heartbeat.sh"

print_success "dev-bringup: complete"
