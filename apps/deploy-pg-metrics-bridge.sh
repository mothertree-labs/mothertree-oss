#!/bin/bash

# Deploy PG Metrics Bridge
# Purpose: Deploy a lightweight pod that bridges the Tailscale mesh to in-cluster
#          Prometheus, forwarding postgres_exporter metrics from the external PG VM.
#
# Creates:
#   - ServiceAccount + RBAC (for Tailscale state Secret management)
#   - Secret (Tailscale auth key — minted/verified via the Headscale API)
#   - Deployment (socat proxy + Tailscale sidecar, 1 replica)
#   - Service (ClusterIP port 9187)
#
# Called by: deploy_infra (after PgBouncer deployment)
# Can also be run standalone.
#
# Usage:
#   ./apps/deploy-pg-metrics-bridge.sh -e <env>

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  echo "Usage: $0 -e <env>"
  echo ""
  echo "Deploy PG metrics bridge (socat + Tailscale) to forward postgres_exporter"
  echo "metrics from the external PG VM into the cluster for Prometheus scraping."
  echo ""
  echo "Options:"
  echo "  -e <env>       Environment (e.g., dev, prod)"
  echo "  -h, --help     Show this help"
}

mt_parse_args "$@"
mt_require_env

# Load infrastructure configuration
source "${REPO_ROOT}/scripts/lib/infra-config.sh"
mt_load_infra_config

mt_require_commands kubectl envsubst

MANIFESTS_DIR="$REPO_ROOT/apps/manifests/pg-metrics-bridge"

# =============================================================================
# Validate required config
# =============================================================================

: "${PG_VM_TAILSCALE_IP:?PG_VM_TAILSCALE_IP not set. Add pgbouncer.pg_vm_tailscale_ip to infra config.}"
export PG_VM_TAILSCALE_IP

: "${HEADSCALE_URL:?HEADSCALE_URL not set. Add headscale.url to infra config.}"
export HEADSCALE_URL

# Tailscale pre-auth keys are minted through the Headscale API (tag:monitoring, 90 days)
# on first-time bootstrap and whenever the key in the Secret turns out to be
# missing, untagged, single-use, expired or near expiry (#613). The in-cluster
# key-rotator CronJob runs the same check daily. See scripts/lib/tailscale-keys.sh.
: "${TAILSCALE_ROTATOR_API_KEY:?tailscale.rotator_api_key not set in infra secrets — required to mint/verify the PG metrics bridge sidecar pre-auth key (headscale apikeys create --expiration 87600h)}"
HEADSCALE_API_KEY="$TAILSCALE_ROTATOR_API_KEY"
source "${REPO_ROOT}/scripts/lib/tailscale-keys.sh"

print_status "Deploying PG metrics bridge to $NS_DB (env: $MT_ENV)"
print_status "  PG VM Tailscale IP: $PG_VM_TAILSCALE_IP"
print_status "  Headscale URL: $HEADSCALE_URL"

# =============================================================================
# Apply RBAC
# =============================================================================

print_status "Applying PG metrics bridge RBAC..."
mt_reset_change_tracker
envsubst '${NS_DB}' < "$MANIFESTS_DIR/rbac.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply Secret
# =============================================================================

# Tailscale auth secret: verify the key it holds against Headscale; mint and
# write a tag:monitoring key if the Secret is missing or its key is unusable
# (this Secret held an untagged key that expired 2026-03-31 for five months
# before a pod recreation surfaced it — #613). A write flags the change
# tracker, so the restart below picks the key up.
print_status "Verifying PG metrics bridge Tailscale auth key..."
mt_ts_ensure_secret "$NS_DB" pg-metrics-bridge-tailscale-auth tag:monitoring pg-metrics-bridge

# =============================================================================
# Apply Deployment
# =============================================================================

print_status "Applying PG metrics bridge Deployment..."
envsubst '${NS_DB} ${PG_VM_TAILSCALE_IP} ${HEADSCALE_URL}' \
  < "$MANIFESTS_DIR/deployment.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply Service
# =============================================================================

print_status "Applying PG metrics bridge Service..."
envsubst '${NS_DB}' < "$MANIFESTS_DIR/service.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Conditional restart
# =============================================================================

mt_restart_if_changed deployment/pg-metrics-bridge -n "$NS_DB"

# =============================================================================
# Wait for rollout
# =============================================================================

if mt_has_changes; then
  print_status "Waiting for PG metrics bridge rollout..."
  kubectl rollout status deployment/pg-metrics-bridge -n "$NS_DB" --timeout=120s
fi

print_success "PG metrics bridge deployed to $NS_DB"
