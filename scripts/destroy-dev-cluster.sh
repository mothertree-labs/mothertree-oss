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
# Also does NOT touch the shared VPC (matrix-cluster-<env>-vpc). Even though it
# is defined inside module.lke_cluster, it contains both the LKE cluster_subnet
# (ephemeral) AND the support_subnet (which holds the always-up VMs). Destroying
# the VPC would require evicting the always-up VMs. The cluster_subnet is
# destroyed and recreated each cycle; the VPC + support_subnet persist.
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

# Terraform state entries that MUST still exist after the destroy. If any of
# these disappear, the -target list is wrong and we have widened the blast
# radius beyond the ephemeral cluster.
#
# The VPC is included here even though it lives inside module.lke_cluster: it
# is shared with the support_subnet (always-up VMs) and must persist across
# destroy/recreate cycles. See header for the full rationale.
ALWAYS_UP_TF_MODULES=(
  "module.headscale_server"
  "module.postgres_server"
  "linode_instance.turn_server"
  "module.lke_cluster.linode_vpc.cluster_vpc"
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

  echo "Terraform targets that would be destroyed:"
  echo "  -target=module.lke_cluster.linode_lke_cluster.cluster"
  echo "  -target=module.lke_cluster.linode_vpc_subnet.cluster_subnet"
  echo "  -target=local_file.kubeconfig"
  echo ""

  echo "Always-up resources (will be preserved):"
  echo "  - postgres-dev (VM + 10 Gi data volume)"
  echo "  - headscale-dev (VM + 10 Gi data volume)"
  echo "  - turn-server-dev (VM)"
  echo "  - matrix-cluster-${MT_ENV}-vpc (shared with support_subnet → always-up VMs)"
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

  # 2a — Force-evict known drain blockers. These three workload classes have
  # consistently blocked node drain in dev (verified during Phase 1's pool roll).
  # Each `|| true` covers the case where the resource is already gone.
  print_status "Force-evicting known drain blockers..."

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
  if [ -n "$PG_PASSWORD" ]; then
    # Discover and drop every nextcloud_<tenant> database that exists.
    DROP_SQL=$("${KUBECTL[@]}" run psql-drop-tenants --rm -i --restart=Never \
      --image=postgres:16 --quiet -n default \
      --env "PGHOST=pgbouncer.infra-db.svc.cluster.local" \
      --env "PGUSER=postgres" \
      --env "PGPASSWORD=$PG_PASSWORD" \
      -- psql -tAc "SELECT 'DROP DATABASE IF EXISTS \"' || datname || '\" WITH (FORCE);' FROM pg_database WHERE datname LIKE 'nextcloud\\_%' ESCAPE '\\';" \
      2>/dev/null | grep -E '^DROP DATABASE' || true)
    if [ -n "$DROP_SQL" ]; then
      echo "$DROP_SQL" | sed 's/^/  will run: /'
      "${KUBECTL[@]}" run psql-drop-tenants --rm -i --restart=Never \
        --image=postgres:16 --quiet -n default \
        --env "PGHOST=pgbouncer.infra-db.svc.cluster.local" \
        --env "PGUSER=postgres" \
        --env "PGPASSWORD=$PG_PASSWORD" \
        -- psql -v ON_ERROR_STOP=1 -c "$DROP_SQL" 2>&1 \
        | sed 's/^/  /' || print_warning "  Some DROP statements may have failed"
    else
      echo "  No nextcloud_* databases found, skipping drop"
    fi
  else
    print_warning "Could not load postgres-credentials secret — skipping tenant DB drop"
    print_warning "Cold-start of Nextcloud on the next cycle will likely fail until you drop the DBs manually"
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: terraform destroy (LKE cluster only — never the always-up VMs)
# ---------------------------------------------------------------------------
print_status "Running terraform destroy (LKE cluster only)..."

ENV_DNS_LABEL="$MT_ENV"   # 'dev' (per manage_infra convention; only 'prod' is empty)

pushd "$REPO_ROOT/phase1" >/dev/null

  terraform init -input=false >/dev/null
  terraform workspace select "$MT_ENV"

  VAR_FILE_FLAGS=()
  if [ -f "$REPO_ROOT/terraform.tfvars" ]; then
    VAR_FILE_FLAGS+=("-var-file=$REPO_ROOT/terraform.tfvars")
  fi
  if [ -f "$REPO_ROOT/terraform.${MT_ENV}.tfvars" ]; then
    VAR_FILE_FLAGS+=("-var-file=$REPO_ROOT/terraform.${MT_ENV}.tfvars")
  fi

  # Target only the ephemeral cluster pieces — explicitly NOT the VPC. The VPC
  # is defined inside module.lke_cluster but it is shared with the support_subnet
  # (always-up VMs); targeting `module.lke_cluster` as a whole pulls the VPC in
  # and Linode rejects the delete because the VPC still has resources in it.
  # The post-destroy assertion below double-checks the VPC + always-up VMs
  # survive in state.
  terraform destroy -auto-approve "${VAR_FILE_FLAGS[@]}" \
    -target=module.lke_cluster.linode_lke_cluster.cluster \
    -target=module.lke_cluster.linode_vpc_subnet.cluster_subnet \
    -target=local_file.kubeconfig \
    -var env="$MT_ENV" \
    -var env_dns_label="$ENV_DNS_LABEL" \
    -var jitsi_tester_enabled=false

  # Defense in depth: confirm always-up VM modules survived the destroy.
  print_status "Asserting always-up VMs are still in terraform state..."
  STATE_LIST=$(terraform state list 2>/dev/null)
  for entry in "${ALWAYS_UP_TF_MODULES[@]}"; do
    if ! echo "$STATE_LIST" | grep -q "$entry"; then
      print_error "ASSERTION FAILED: $entry is missing from terraform state!"
      print_error "The destroy widened beyond the ephemeral cluster — this is a bug."
      exit 3
    fi
  done
  print_success "All always-up resources (postgres-dev, headscale-dev, turn-server-dev, VPC) preserved in state"

popd >/dev/null

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
    print_status "  Detaching + deleting tagged orphan: $label (id=$id)"
    linode-cli volumes detach "$id" 2>/dev/null || true
    sleep 2
    linode-cli volumes delete "$id" || print_warning "  Failed to delete volume $id"
  done

# Pass 2: CSI-provisioned orphans. Linode CSI tags volumes with `[]`, labels them
# `pvc-<uuid>`, and uses `linode-block-storage-retain` so they won't auto-delete
# when the cluster goes away. We catch them by label prefix + region + unattached.
#
# IMPORTANT: this filter relies on dev being the only cluster in $CLUSTER_REGION
# with unattached pvc-* volumes at this moment. Prod's CSI volumes will still
# be attached to running prod nodes, so they won't match. If prod ever moves
# into us-lax, this filter must be tightened. (Prod is currently us-east, prod-eu
# is nl-ams — Phase 1 verified.)
print_status "Orphan sweep pass 2: CSI-provisioned orphans (label=pvc-*, unattached, region=$CLUSTER_REGION)..."
linode-cli volumes list --json 2>/dev/null | jq -r --arg region "$CLUSTER_REGION" '
  .[] | select(.label | startswith("pvc-"))
       | select(.region == $region)
       | select(.linode_id == null)
  | "\(.id)\t\(.label)"' \
| while IFS=$'\t' read -r id label; do
    print_status "  Deleting CSI orphan: $label (id=$id)"
    linode-cli volumes delete "$id" || print_warning "  Failed to delete volume $id"
  done

# ---------------------------------------------------------------------------
# Step 5: orphan sweep — NodeBalancers
# ---------------------------------------------------------------------------
# CCM-managed NBs are tagged ONLY ["kubernetes"] (no "dev" tag), so the reliable
# signal is the label format `lke<cluster_id>-<hash>`. LKE *should* clean these
# up on cluster destroy — this is belt-and-suspenders.
if [ -n "${CLUSTER_ID:-}" ]; then
  print_status "Orphan sweep: NodeBalancers labeled lke${CLUSTER_ID}-*..."
  linode-cli nodebalancers list --json 2>/dev/null \
    | jq -r --arg region "$CLUSTER_REGION" --arg prefix "lke${CLUSTER_ID}-" '
        .[] | select(.region == $region) | select(.label | startswith($prefix)) | .id' \
    | while read -r nb_id; do
        print_status "  Deleting NodeBalancer id=$nb_id"
        linode-cli nodebalancers delete "$nb_id" || print_warning "  Failed to delete NB $nb_id"
      done
else
  print_status "Skipping NodeBalancer sweep (no cluster id captured)"
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
echo "  - matrix-cluster-${MT_ENV}-vpc (shared with support_subnet → always-up VMs)"
echo "  - DNS records (Cloudflare)"
echo ""
echo "To rebuild the cluster: ./scripts/manage_infra -e $MT_ENV --phase1 \\"
echo "                        && ./scripts/deploy_infra -e $MT_ENV"
