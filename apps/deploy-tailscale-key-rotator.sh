#!/bin/bash

# Deploy Tailscale Key Rotator CronJob
# Purpose: Deploy a K8s CronJob that automatically rotates Tailscale pre-auth keys
#          by calling the Headscale REST API, then patching K8s secrets and restarting
#          affected deployments.
#
# Creates:
#   - ServiceAccount + RBAC (ClusterRole + RoleBindings per infra namespace)
#   - Secret (Headscale API key)
#   - ConfigMap (rotation script + component config)
#   - CronJob (weekly, Sunday 04:00 UTC)
#
# Called by: deploy_infra
# Can also be run standalone.
#
# Usage:
#   ./apps/deploy-tailscale-key-rotator.sh -e <env>

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  echo "Usage: $0 -e <env>"
  echo ""
  echo "Deploy Tailscale key rotator CronJob to infra-db namespace."
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

MANIFESTS_DIR="$REPO_ROOT/apps/manifests/tailscale-key-rotator"

# =============================================================================
# Validate required config
# =============================================================================

: "${HEADSCALE_URL:?HEADSCALE_URL not set. Add headscale.url to infra config.}"
export HEADSCALE_URL

if [ -z "${TAILSCALE_ROTATOR_API_KEY:-}" ]; then
  print_warning "Tailscale rotator API key not set (tailscale.rotator_api_key in infra secrets)"
  print_warning "Skipping key rotator CronJob deployment"
  print_warning "To enable: create API key on Headscale (headscale apikeys create --expiration 87600h)"
  exit 0
fi

print_status "Deploying Tailscale key rotator to $NS_DB (env: $MT_ENV)"
print_status "  Headscale URL: $HEADSCALE_URL"

# =============================================================================
# Apply RBAC
# =============================================================================

print_status "Applying key rotator RBAC..."
mt_reset_change_tracker
envsubst '${NS_DB} ${NS_MAIL} ${NS_INGRESS_INTERNAL}' \
  < "$MANIFESTS_DIR/rbac.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply Secret (API key)
# =============================================================================

print_status "Applying rotator API key secret..."
envsubst '${NS_DB} ${TAILSCALE_ROTATOR_API_KEY}' \
  < "$MANIFESTS_DIR/secret.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply ConfigMap (rotation script + component config)
# =============================================================================

print_status "Applying key rotator ConfigMap..."
envsubst '${NS_DB} ${NS_MAIL} ${NS_INGRESS_INTERNAL} ${HEADSCALE_URL}' \
  < "$MANIFESTS_DIR/configmap.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply CronJob
# =============================================================================

print_status "Applying key rotator CronJob..."
envsubst '${NS_DB}' \
  < "$MANIFESTS_DIR/cronjob.yaml.tpl" | mt_apply kubectl apply -f -

print_success "Tailscale key rotator deployed to $NS_DB"
echo "  Schedule: weekly (Sunday 04:00 UTC)"
echo "  Manual trigger: kubectl create job --from=cronjob/tailscale-key-rotator test-rotation -n $NS_DB"
