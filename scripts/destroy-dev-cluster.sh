#!/bin/bash

# Destroy Dev LKE Cluster (ephemeral)
#
# Purpose: Tear down the dev LKE cluster and the LKE-side resources it creates
#          (CCM-managed NodeBalancer, CSI-provisioned PVCs/block volumes), so
#          that nothing keeps billing while dev is "off".
#
# Explicitly does NOT touch the always-up VMs:
#   - postgres-dev   (Linode VM + 10 Gi data volume)
#   - headscale-dev  (Linode VM + 10 Gi data volume)
#   - turn-server-dev (Linode VM)
#
# Also does NOT touch the LKE VPC (matrix-cluster-<env>-vpc) or the on-demand-dev
# heartbeat bucket. Both live in phase1-dev's S3-backed state and are preserved
# across destroy/recreate cycles: the cluster_subnet is the only VPC-side
# resource that cycles, and the heartbeat bucket must outlive the cluster so
# the Phase 3 reaper can see "the cluster was last used at T".
#
# These are kept across destroy/recreate cycles. The cost/benefit of cycling
# postgres-dev (~$13/mo) is poor: it's outside K8s, schema bootstrap is painful,
# and the volume is already at Linode's 10 Gi block-storage minimum.
#
# Idempotent: safe to re-run on an already-destroyed cluster.
# Phase 2 of the on-demand-dev plan; Phase 3 will wire this into a CI reaper.
#
# Usage:
#   ./scripts/destroy-dev-cluster.sh -e dev
#   ./scripts/destroy-dev-cluster.sh -e dev --dry-run
#   ./scripts/destroy-dev-cluster.sh -e dev --no-lock   # placeholder for Phase 3
#
# Exit codes:
#   0 — success
#   1 — generic failure (set -e, command failures)
#   2 — wrong env (must be 'dev')
#   3 — post-destroy assertion failed: an always-up resource disappeared
#   4 — postgres-credentials Secret unavailable (would skip tenant DB drop)
#   5 — discovered DB name failed the safe-identifier allowlist regex
#   6 — DROP DATABASE failed on a discovered tenant DB
#   7 — found a tagged 'dev' volume not in ALWAYS_UP_VOLUMES with an operator-style
#       label (refuses to auto-delete; whitelist update needed)

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  cat <<EOF
Usage: $0 -e dev [options]

Destroys the dev LKE cluster + LKE-side resources (NodeBalancer, CSI volumes).
Does NOT touch postgres-dev, headscale-dev, or turn-server-dev (always-up VMs).

Options:
  -e dev        Environment (must be 'dev')
  --dry-run     Print resolved targets without destroying anything
  --no-lock     Skip lock acquisition (Phase 3 placeholder; for now this is a no-op)
  -h, --help    Show this help
EOF
}

mt_parse_args "$@"
mt_require_env

# Hard guard: this script only supports dev. The cost model and the always-up VM
# whitelist below are dev-specific.
if [ "$MT_ENV" != "dev" ]; then
  print_error "destroy-dev-cluster.sh only supports 'dev' (got '$MT_ENV')"
  exit 2
fi

DRY_RUN="false"
if mt_has_flag "--dry-run"; then DRY_RUN="true"; fi

# Volumes that must NEVER be deleted by this script. These are attached to
# always-up VMs that live outside the LKE cluster lifecycle.
ALWAYS_UP_VOLUMES=(
  "postgres-dev-data"
  "headscale-dev-data"
)

# VMs that must NEVER be touched by this script. Verified post-destroy via the
# Linode API by label — NOT `terraform state list`. The phase1 dev VMs live in
# a workspace with a LOCAL backend that exists only on an operator machine; it
# is absent on the CI/reaper host, so a terraform-state assertion there fails
# (`Workspace "dev" doesn't exist`) and, under `set -e`, used to abort the
# script before the orphan sweeps in Steps 4–5 ever ran — leaking a
# NodeBalancer + CSI volumes on every reaper recycle. An API check is both
# CI-safe and stronger (asserts the VMs really exist + run, not just that a
# state file names them).
ALWAYS_UP_VMS=(
  "postgres-${MT_ENV}"
  "headscale-${MT_ENV}"
  "turn-server-${MT_ENV}"
)

# Terraform state entries that MUST still exist after the destroy. If any of
# these disappear, the -target list is wrong and we have widened the blast
# radius beyond the ephemeral cluster. Only phase1-dev is checked here: it uses
# a Linode Object Storage backend reachable from both operator and CI hosts
# (the always-up VMs are asserted via ALWAYS_UP_VMS above instead).
ALWAYS_UP_TF_MODULES_PHASE1_DEV=(
  "module.lke_cluster.linode_vpc.cluster_vpc"
  "linode_object_storage_bucket.dev_state"
  "linode_object_storage_key.dev_state"
)

CLUSTER_REGION="us-lax"
CLUSTER_LABEL="matrix-cluster-${MT_ENV}"

# All kubectl calls go via this wrapper so a stale kubeconfig pointing at a
# destroyed cluster cannot hang the script.
KUBECTL=(kubectl --kubeconfig="${REPO_ROOT}/kubeconfig.${MT_ENV}.yaml" --request-timeout=30s)

mt_require_commands linode-cli jq terraform kubectl

# Load shared infra secrets (linode_token, cloudflare_*, ssh_public_key) for terraform.
# Match manage_infra's lookup order.
if [ -f "$REPO_ROOT/secrets.tfvars.env" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/secrets.tfvars.env"
elif [ -f "$REPO_ROOT/secrets.${MT_ENV}.tfvars.env" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/secrets.${MT_ENV}.tfvars.env"
else
  print_error "No secrets file found. Expected $REPO_ROOT/secrets.tfvars.env"
  exit 1
fi

# linode-cli looks for LINODE_CLI_TOKEN in env. Map from terraform var if not set.
export LINODE_CLI_TOKEN="${LINODE_CLI_TOKEN:-${TF_VAR_linode_token:-}}"
if [ -z "${LINODE_CLI_TOKEN:-}" ]; then
  print_error "LINODE_CLI_TOKEN (or TF_VAR_linode_token) is required"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: detect cluster
# ---------------------------------------------------------------------------
print_status "Looking up '$CLUSTER_LABEL' in Linode..."
CLUSTER_ID=$(linode-cli lke clusters-list --json 2>/dev/null \
  | jq -r --arg label "$CLUSTER_LABEL" '.[] | select(.label == $label) | .id // empty')

if [ -z "$CLUSTER_ID" ]; then
  print_warning "No LKE cluster '$CLUSTER_LABEL' found — skipping K8s sweep + terraform destroy"
  CLUSTER_EXISTS=false
else
  print_status "Found cluster id=$CLUSTER_ID"
  CLUSTER_EXISTS=true
fi

# ---------------------------------------------------------------------------
# Dry-run: print what we would do, then exit
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = "true" ]; then
  echo ""
  print_status "=== DRY RUN ==="
  echo "Cluster:        $CLUSTER_LABEL (id=${CLUSTER_ID:-<not found>})"
  echo "Region:         $CLUSTER_REGION"
  echo ""

  echo "Terraform targets that would be destroyed (phase1-dev / S3-backed state):"
  echo "  -target=module.lke_cluster.linode_lke_cluster.cluster"
  echo "  -target=module.lke_cluster.linode_vpc_subnet.cluster_subnet"
  echo "  -target=local_file.kubeconfig"
  echo ""

  echo "Always-up resources (will be preserved):"
  echo "  - postgres-dev (VM + 10 Gi data volume)               [phase1 dev workspace]"
  echo "  - headscale-dev (VM + 10 Gi data volume)              [phase1 dev workspace]"
  echo "  - turn-server-dev (VM)                                [phase1 dev workspace]"
  echo "  - matrix-cluster-${MT_ENV}-vpc                        [phase1-dev]"
  echo "  - mothertree-dev-state Object Storage bucket + key    [phase1-dev]"
  echo ""

  if [ "$CLUSTER_EXISTS" = "true" ]; then
    echo "Drain blockers that would be force-evicted:"
    "${KUBECTL[@]}" get pods -A -l app=jitsi-jvb --no-headers 2>/dev/null \
      | awk '{print "  jitsi-jvb: " $1 "/" $2}' || true
    "${KUBECTL[@]}" get pod keycloak-keycloakx-0 -n infra-auth --no-headers 2>/dev/null \
      | awk '{print "  keycloak: infra-auth/" $1}' || true
    "${KUBECTL[@]}" get pods -n infra-ingress-internal -l app.kubernetes.io/name=ingress-nginx --no-headers 2>/dev/null \
      | awk '{print "  ingress-internal: infra-ingress-internal/" $1}' || true
    echo ""

    echo "PVCs that would be deleted (cluster-wide):"
    "${KUBECTL[@]}" get pvc -A --no-headers 2>/dev/null \
      | awk '{print "  " $1 "/" $2 " (" $4 ")"}' || true
    echo ""

    echo "Tenant Nextcloud databases that would be dropped (postgres-dev, via PgBouncer):"
    PG_PASSWORD=$("${KUBECTL[@]}" get secret postgres-credentials -n infra-db \
      -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d || true)
    if [ -n "$PG_PASSWORD" ]; then
      "${KUBECTL[@]}" run psql-list-tenants --rm -i --restart=Never \
        --image=postgres:16 --quiet -n default \
        --env "PGHOST=pgbouncer.infra-db.svc.cluster.local" \
        --env "PGUSER=postgres" \
        --env "PGPASSWORD=$PG_PASSWORD" \
        -- psql -tAc "SELECT datname FROM pg_database WHERE datname LIKE 'nextcloud\\_%' ESCAPE '\\';" 2>/dev/null \
        | grep -v '^$' | awk '{print "  " $1}' || echo "  (query failed)"
    else
      echo "  (postgres-credentials secret unavailable — would skip drop)"
    fi
    echo ""
  fi

  echo "Volume orphan-sweep candidates (region=$CLUSTER_REGION, tag=dev):"
  linode-cli volumes list --json 2>/dev/null | jq -r --arg region "$CLUSTER_REGION" '
    .[] | select(.tags | index("dev")) | select(.region == $region)
    | "  \(.id)\t\(.label)\t(\(.size) Gi)"' || true
  echo ""

  echo "CSI orphan-sweep candidates (region=$CLUSTER_REGION, label=pvc-*, unattached):"
  linode-cli volumes list --json 2>/dev/null | jq -r --arg region "$CLUSTER_REGION" '
    .[] | select(.label | startswith("pvc-")) | select(.region == $region) | select(.linode_id == null)
    | "  \(.id)\t\(.label)\t(\(.size) Gi)"' || true
  echo ""

  echo "NodeBalancer orphan-sweep candidates:"
  if [ -n "$CLUSTER_ID" ]; then
    linode-cli nodebalancers list --json 2>/dev/null | jq -r --arg region "$CLUSTER_REGION" --arg prefix "lke${CLUSTER_ID}-" '
      .[] | select(.region == $region) | select(.label | startswith($prefix))
      | "  \(.id)\t\(.label)"' || true
  else
    echo "  (cluster id unknown — would skip NB sweep)"
  fi

  print_status "Dry run complete. No changes made."
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 2: K8s pre-destroy sweep (if cluster exists)
# ---------------------------------------------------------------------------
if [ "$CLUSTER_EXISTS" = "true" ]; then

  # 2a — Force-terminate pods that hold PVCs or have problematic finalizers,
  # so the PVC sweep in 2b can release the underlying Linode block volumes
  # cleanly. Without this, the orphan sweep in step 4 has to scoop up leaked
  # CSI volumes. Each `|| true` covers the case where the resource is already
  # gone (idempotency).
  print_status "Force-evicting pods that block clean PVC release..."

  # Stuck Jitsi JVB pods (label is `app=jitsi-jvb`, NOT `app.kubernetes.io/name`).
  # Pods stick in Terminating for tens of days due to a hostPort/UDP cleanup quirk.
  "${KUBECTL[@]}" get pods -A -l app=jitsi-jvb -o name 2>/dev/null \
    | xargs -r -I{} "${KUBECTL[@]}" delete {} --force --grace-period=0 --ignore-not-found 2>&1 \
    | sed 's/^/  /' || true

  # Keycloak StatefulSet — strict podAntiAffinity prevents in-place migration.
  "${KUBECTL[@]}" delete pod keycloak-keycloakx-0 -n infra-auth --grace-period=10 --ignore-not-found 2>&1 \
    | sed 's/^/  /' || true

  # Internal ingress controller — PDB blocks ordinary eviction.
  "${KUBECTL[@]}" delete pods -n infra-ingress-internal \
    -l app.kubernetes.io/name=ingress-nginx --grace-period=10 --ignore-not-found 2>&1 \
    | sed 's/^/  /' || true

  # 2b — PVC sweep. Triggers Linode CSI to release the underlying block volumes
  # cleanly (the `linode-block-storage-retain` storage class won't auto-delete
  # otherwise — those become the orphans pass 2 sweeps below).
  print_status "Deleting all PVCs cluster-wide (triggers CSI volume release)..."
  "${KUBECTL[@]}" delete pvc --all -A --timeout=120s --ignore-not-found 2>&1 \
    | sed 's/^/  /' || true

  # Wait up to 60s for PVs to fully detach. Best-effort — if some are stuck,
  # the orphan sweep below will catch them.
  print_status "Waiting for PVs to detach..."
  for _ in {1..30}; do
    pv_count=$("${KUBECTL[@]}" get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$pv_count" = "0" ]; then
      print_success "All PVs detached"
      break
    fi
    echo "  $pv_count PV(s) still present..."
    sleep 2
  done

  # 2c — Drop tenant Nextcloud databases via the in-cluster PgBouncer.
  # The postgres-dev VM is preserved across destroy/recreate cycles (always-up),
  # which means the tenant DBs persist too. For Nextcloud specifically this
  # breaks cold-start: the DB has tables + appconfig from the previous cycle,
  # but the K8s `nextcloud-identity` Secret (which encodes config.php identity
  # values) is destroyed with the cluster. The new pods can't replay the prior
  # install state, the entrypoint sees the existing DB and skips install, and
  # the deploy script then fails on `occ config:system:set` because Nextcloud
  # reports installed=false. Dropping the DB lets the next deploy reinstall
  # cleanly from an empty schema. (See PR notes for the full incident.)
  #
  # We run this BEFORE terraform destroy because PgBouncer is in-cluster — once
  # the cluster is gone, the only path to postgres-dev is via direct Tailscale,
  # which the operator's local machine doesn't always have.
  print_status "Dropping tenant Nextcloud databases via in-cluster PgBouncer..."
  PG_PASSWORD=$("${KUBECTL[@]}" get secret postgres-credentials -n infra-db \
    -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d || true)
  if [ -z "$PG_PASSWORD" ]; then
    print_error "Could not load postgres-credentials secret — refusing to continue."
    print_error "Cold-start of Nextcloud on the next cycle would fail. Either drop the DBs"
    print_error "manually before re-running this script, or fix the postgres-credentials Secret."
    exit 4
  fi
  # Discover nextcloud_<tenant> databases. Output one name per line.
  TENANT_DBS=$("${KUBECTL[@]}" run psql-list-tenants --rm -i --restart=Never \
    --image=postgres:16 --quiet -n default \
    --env "PGHOST=pgbouncer.infra-db.svc.cluster.local" \
    --env "PGUSER=postgres" \
    --env "PGPASSWORD=$PG_PASSWORD" \
    -- psql -tAc "SELECT datname FROM pg_database WHERE datname LIKE 'nextcloud\\_%' ESCAPE '\\';" \
    2>/dev/null | grep -E '^[a-z0-9_-]+$' || true)
  if [ -z "$TENANT_DBS" ]; then
    echo "  No nextcloud_* databases found, skipping drop"
  else
    while IFS= read -r db; do
      # Allowlist regex defends against SQL identifier injection. tenant DB names
      # are operator-controlled via deploy scripts and always match `nextcloud_<tenant>`
      # with lowercase + digits + underscore/hyphen; anything else is suspicious.
      if [[ ! "$db" =~ ^nextcloud_[a-z0-9][a-z0-9_-]*$ ]]; then
        print_error "  Refusing to drop suspicious DB name: $db"
        exit 5
      fi
      print_status "  Dropping $db"
      # DROP DATABASE cannot run inside a transaction block, so each DROP must
      # be its own psql -c invocation (one auto-commit transaction each).
      "${KUBECTL[@]}" run psql-drop --rm -i --restart=Never \
        --image=postgres:16 --quiet -n default \
        --env "PGHOST=pgbouncer.infra-db.svc.cluster.local" \
        --env "PGUSER=postgres" \
        --env "PGPASSWORD=$PG_PASSWORD" \
        -- psql -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE);" 2>&1 \
        | sed 's/^/    /' \
        || { print_error "  Failed to drop $db — aborting"; exit 6; }
    done <<< "$TENANT_DBS"
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: terraform destroy (LKE cluster only — never the always-up VMs)
#
# The LKE cluster lives in phase1-dev/ (its own S3-backed state). The dev VMs
# live in phase1/ (dev workspace, local state) and are NOT touched here.
# ---------------------------------------------------------------------------
print_status "Running terraform destroy (LKE cluster only, in phase1-dev)..."

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  print_error "phase1-dev S3 backend requires AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in your secrets env."
  print_error "See phase1-dev/MIGRATION.md."
  exit 1
fi

VAR_FILE_FLAGS=()
if [ -f "$REPO_ROOT/terraform.tfvars" ]; then
  VAR_FILE_FLAGS+=("-var-file=$REPO_ROOT/terraform.tfvars")
fi
if [ -f "$REPO_ROOT/terraform.${MT_ENV}.tfvars" ]; then
  VAR_FILE_FLAGS+=("-var-file=$REPO_ROOT/terraform.${MT_ENV}.tfvars")
fi

pushd "$REPO_ROOT/phase1-dev" >/dev/null

  terraform init -input=false >/dev/null

  # Target only the ephemeral cluster pieces — NOT the VPC, the heartbeat
  # bucket, or its access key. The post-destroy assertion below double-checks
  # they survive in state.
  terraform destroy -auto-approve "${VAR_FILE_FLAGS[@]}" \
    -target=module.lke_cluster.linode_lke_cluster.cluster \
    -target=module.lke_cluster.linode_vpc_subnet.cluster_subnet \
    -target=local_file.kubeconfig

  # Defense in depth: confirm VPC + heartbeat bucket survived. Anchor the match
  # to a full module/resource path so substring rename collisions don't slip by.
  print_status "Asserting VPC + heartbeat bucket are still in phase1-dev state..."
  STATE_LIST_PHASE1_DEV=$(terraform state list 2>/dev/null)
  for entry in "${ALWAYS_UP_TF_MODULES_PHASE1_DEV[@]}"; do
    if ! echo "$STATE_LIST_PHASE1_DEV" | grep -qE "^${entry}(\.|$)"; then
      print_error "ASSERTION FAILED: $entry is missing from phase1-dev terraform state!"
      print_error "The destroy widened beyond the ephemeral cluster — this is a bug."
      exit 3
    fi
  done
  print_success "VPC + heartbeat bucket preserved in phase1-dev state"

popd >/dev/null

# Verify the always-up dev VMs are untouched. This script never invokes
# terraform against phase1/, and phase1's dev workspace uses a LOCAL backend
# that does not exist on the CI/reaper host — so we assert against the Linode
# API by VM label rather than `terraform state list`. CI-safe, and a stronger
# check (the VMs must actually exist, not merely be named in a state file).
print_status "Asserting always-up VMs still exist (Linode API)..."
# Fail closed with a clear diagnostic on API failure, rather than a bare `set -e`
# abort (which would otherwise misreport as "VM not found"). Either way nothing
# has been swept yet, so this fails safe — but the operator/reaper log should
# say *why*.
if ! ALL_LINODES_JSON=$(linode-cli linodes list --json); then
  print_error "linode-cli linodes list failed — cannot verify always-up VMs; aborting before any orphan sweep (fail closed)"
  exit 3
fi
for vm in "${ALWAYS_UP_VMS[@]}"; do
  vm_status=$(echo "$ALL_LINODES_JSON" | jq -r --arg l "$vm" '.[] | select(.label == $l) | .status // empty')
  if [ -z "$vm_status" ]; then
    print_error "ASSERTION FAILED: always-up VM '$vm' not found in the Linode account!"
    print_error "destroy-dev-cluster.sh must never touch the always-up VMs — investigate immediately."
    exit 3
  fi
  print_status "  $vm: $vm_status"
done
print_success "All always-up resources (postgres-dev, headscale-dev, turn-server-dev, VPC, heartbeat bucket) preserved"

# ---------------------------------------------------------------------------
# Step 4: orphan sweep — block volumes (two-pass)
# ---------------------------------------------------------------------------

# Pass 1: Terraform-tagged 'dev' volumes that somehow survived terraform destroy.
# Belt-and-suspenders — should be empty in practice. Skips the always-up VM
# data volumes by label.
print_status "Orphan sweep pass 1: tagged 'dev' volumes..."
linode-cli volumes list --json 2>/dev/null | jq -r --arg region "$CLUSTER_REGION" '
  .[] | select(.tags | index("dev")) | select(.region == $region)
  | "\(.id)\t\(.label)"' \
| while IFS=$'\t' read -r id label; do
    # Skip the always-up VM data volumes — these are the whole point of "always-up".
    skip=false
    for protected in "${ALWAYS_UP_VOLUMES[@]}"; do
      if [ "$label" = "$protected" ]; then skip=true; break; fi
    done
    if [ "$skip" = "true" ]; then
      echo "  Preserving always-up volume: $label (id=$id)"
      continue
    fi
    # Defense: only auto-delete CSI-managed volumes (label `pvc-<uuid>`). A
    # tagged 'dev' volume with a human label that ISN'T in ALWAYS_UP_VOLUMES is
    # suspicious — it's probably a new always-up resource whose maintainer
    # forgot to add it to the whitelist. Refuse rather than silently destroy.
    if ! echo "$label" | grep -qE '^pvc-'; then
      print_error "Refusing to delete tagged 'dev' volume with operator-style label: $label (id=$id)"
      print_error "If this is a new always-up resource, add it to ALWAYS_UP_VOLUMES in this script."
      print_error "If this is a real orphan, delete it manually: linode-cli volumes delete $id"
      exit 7
    fi
    print_status "  Detaching + deleting tagged orphan: $label (id=$id)"
    linode-cli volumes detach "$id" 2>/dev/null || true
    sleep 2
    linode-cli volumes delete "$id" || print_warning "  Failed to delete volume $id"
  done

# Pass 2: CSI-provisioned orphans. Linode CSI tags volumes with `[]`, labels them
# `pvc-<uuid>`, and uses `linode-block-storage-retain` so they won't auto-delete
# when the cluster goes away.
#
# OPT-IN ONLY (default OFF). prod and dev are BOTH in us-lax (the old comment
# claiming prod is us-east is stale — the prod cluster is also us-lax), and CSI
# pvc-* volumes carry NO cluster fingerprint (empty tags, opaque pvc-<uuid>
# label). A prod CSI volume that is momentarily unattached (pod reschedule,
# node replacement, fresh deploy) is indistinguishable from a dev orphan, so an
# automatic region-wide sweep can irreversibly delete prod data. An age guard
# alone is insufficient (a prod PVC created within the window and briefly
# detached during a reaper run still matches). Until CSI volumes are tagged at
# provision time (the proper fix — recommended follow-up), this sweep runs ONLY
# when SWEEP_CSI_ORPHANS=true is explicitly set, and even then is bounded by
# CSI_ORPHAN_MAX_AGE_DAYS. The reaper does NOT set it: dev pvc-* orphans
# (~$1/mo each) are cleaned up by an operator who can verify them individually.
# The NodeBalancer sweep below (the ~$10/mo-per-cycle cost) IS safe to automate
# because NB labels embed the cluster id.
if [ "${SWEEP_CSI_ORPHANS:-false}" = "true" ]; then
  CSI_ORPHAN_MAX_AGE_DAYS="${CSI_ORPHAN_MAX_AGE_DAYS:-7}"
  CSI_ORPHAN_CUTOFF=$(date -u -d "-${CSI_ORPHAN_MAX_AGE_DAYS} days" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
    || date -u -v-"${CSI_ORPHAN_MAX_AGE_DAYS}"d +%Y-%m-%dT%H:%M:%S)
  print_warning "SWEEP_CSI_ORPHANS=true — pass 2: pvc-* unattached in $CLUSTER_REGION created≥${CSI_ORPHAN_CUTOFF}Z (prod shares this region — verify!)"
  if ! CSI_VOLS_JSON=$(linode-cli volumes list --json); then
    print_error "linode-cli volumes list failed — skipping CSI sweep (fail closed)"
  else
    echo "$CSI_VOLS_JSON" \
      | jq -r --arg region "$CLUSTER_REGION" --arg cutoff "$CSI_ORPHAN_CUTOFF" '
      .[] | select(.label | startswith("pvc-"))
           | select(.region == $region)
           | select(.linode_id == null)
           | select(.created > $cutoff)
      | "\(.id)\t\(.label)"' \
    | while IFS=$'\t' read -r id label; do
        print_status "  Deleting CSI orphan: $label (id=$id)"
        linode-cli volumes delete "$id" || print_warning "  Failed to delete volume $id"
      done
  fi
else
  print_status "Skipping CSI volume orphan sweep (SWEEP_CSI_ORPHANS not set — prod shares us-lax; clean pvc-* manually)"
fi

# ---------------------------------------------------------------------------
# Step 5: orphan sweep — NodeBalancers
# ---------------------------------------------------------------------------
# CCM-managed NBs are tagged ONLY ["kubernetes"] (no "dev" tag); the reliable
# signal is the label format `lke<cluster_id>-<hash>`. LKE *should* delete these
# on cluster destroy but doesn't always.
#
# We sweep ANY NodeBalancer whose embedded cluster id is not a currently-live
# LKE cluster — NOT just the cluster destroyed this run. The old per-CLUSTER_ID
# filter missed leaks from earlier recycle cycles entirely (and was skipped
# whenever CLUSTER_ID was empty, e.g. an idempotent re-run after the cluster was
# already gone — exactly the case that leaked). A dead cluster id can only
# belong to a destroyed cluster, so live prod / prod-eu / fresh-dev NBs are
# never at risk; this is unambiguous and self-heals historical leaks.
print_status "Orphan sweep: NodeBalancers with no live LKE cluster..."
# FAIL CLOSED. If we cannot positively enumerate live clusters, an empty list
# would make EVERY lke<id>- NB (incl. prod + prod-eu) look orphaned — a single
# transient API hiccup must never cascade into deleting production load
# balancers. So: abort the sweep unless the live-cluster lookup succeeds AND
# returns a non-empty, all-numeric id list. prod + prod-eu always exist, so an
# empty result unambiguously means an API failure, not "no clusters."
if ! LIVE_CLUSTERS_JSON=$(linode-cli lke clusters-list --json); then
  print_error "linode-cli lke clusters-list failed — SKIPPING NodeBalancer sweep (fail closed; will retry next recycle)"
else
  LIVE_LKE_IDS=$(echo "$LIVE_CLUSTERS_JSON" | jq -r '.[].id // empty' | grep -E '^[0-9]+$' || true)
  if [ -z "${LIVE_LKE_IDS//[[:space:]]/}" ]; then
    print_error "Live LKE cluster list is empty/unparseable — SKIPPING NodeBalancer sweep (fail closed; prod/prod-eu must always be present)"
  else
    linode-cli nodebalancers list --json 2>/dev/null \
      | jq -r '.[] | select(.label | test("^lke[0-9]+-")) | "\(.id)\t\(.label)"' \
      | while IFS=$'\t' read -r nb_id nb_label; do
          nb_cluster_id=$(echo "$nb_label" | sed -E 's/^lke([0-9]+)-.*/\1/')
          if echo "$LIVE_LKE_IDS" | grep -qx "$nb_cluster_id"; then
            continue   # backed by a live cluster (prod, prod-eu, fresh dev) — keep
          fi
          print_status "  Deleting orphaned NodeBalancer id=$nb_id ($nb_label — dead cluster $nb_cluster_id)"
          linode-cli nodebalancers delete "$nb_id" || print_warning "  Failed to delete NB $nb_id"
        done
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
print_success "Dev cluster destroy complete."
echo ""
echo "Always-up resources preserved:"
echo "  - postgres-dev VM + 10 Gi data volume"
echo "  - headscale-dev VM + 10 Gi data volume"
echo "  - turn-server-dev VM"
echo "  - matrix-cluster-${MT_ENV}-vpc (LKE VPC, in phase1-dev state)"
echo "  - mothertree-dev-state Object Storage bucket + scoped access key"
echo "  - DNS records (Cloudflare)"
echo ""
echo "To rebuild the cluster: ./scripts/manage_infra -e $MT_ENV --phase1 \\"
echo "                        && ./scripts/deploy_infra -e $MT_ENV"
