#!/bin/bash

# Deploy PG Metrics Bridge
# Purpose: Deploy a lightweight pod that bridges the Tailscale mesh to in-cluster
#          Prometheus, forwarding postgres_exporter metrics from the external PG VM.
#
# Creates:
#   - ServiceAccount + RBAC (for Tailscale state Secret management)
#   - Secret (Tailscale auth key)
#   - Deployment (socat proxy + Tailscale sidecar, 1 replica)
#   - Service (ClusterIP port 9187)
#
# Called by: deploy_infra (when PGBOUNCER_ENABLED=true)
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

: "${TAILSCALE_AUTHKEY:?TAILSCALE_AUTHKEY not set. Add tailscale.authkey to infra secrets.}"

print_status "Deploying PG metrics bridge to $NS_DB (env: $MT_ENV)"
print_status "  PG VM Tailscale IP: $PG_VM_TAILSCALE_IP"

# =============================================================================
# Apply RBAC
# =============================================================================

print_status "Applying PG metrics bridge RBAC..."
mt_reset_change_tracker
envsubst '${NS_DB}' < "$MANIFESTS_DIR/rbac.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply Secret
# =============================================================================

print_status "Applying PG metrics bridge Tailscale auth Secret..."
envsubst '${NS_DB} ${TAILSCALE_AUTHKEY}' \
  < "$MANIFESTS_DIR/secret.yaml.tpl" | mt_apply kubectl apply -f -

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

print_status "Waiting for PG metrics bridge rollout..."
kubectl rollout status deployment/pg-metrics-bridge -n "$NS_DB" --timeout=120s

print_success "PG metrics bridge deployed to $NS_DB"
