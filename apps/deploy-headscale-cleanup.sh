#!/bin/bash

# Deploy Headscale Cleanup CronJob
# Purpose: Deploy a K8s CronJob that removes stale Headscale node registrations
#          from K8s pod churn (PgBouncer, Postfix, pg-metrics-bridge).
#          Uses the Headscale REST API — no SSH required.
#
# Reuses the tailscale-rotator-api-key secret (same API key).
#
# Creates:
#   - ConfigMap (cleanup script)
#   - CronJob (hourly at :15)
#
# Called by: deploy_infra
# Can also be run standalone.
#
# Usage:
#   ./apps/deploy-headscale-cleanup.sh -e <env>

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  echo "Usage: $0 -e <env>"
  echo ""
  echo "Deploy Headscale stale node cleanup CronJob to infra-db namespace."
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

MANIFESTS_DIR="$REPO_ROOT/apps/manifests/headscale-cleanup"

# =============================================================================
# Validate required config
# =============================================================================

: "${HEADSCALE_URL:?HEADSCALE_URL not set. Add headscale.url to infra config.}"
export HEADSCALE_URL

if [ -z "${TAILSCALE_ROTATOR_API_KEY:-}" ]; then
  print_warning "Tailscale rotator API key not set — skipping headscale-cleanup CronJob"
  exit 0
fi

print_status "Deploying Headscale cleanup CronJob to $NS_DB (env: $MT_ENV)"
print_status "  Headscale URL: $HEADSCALE_URL"

# =============================================================================
# Apply ConfigMap (cleanup script)
# =============================================================================

print_status "Applying cleanup ConfigMap..."
mt_reset_change_tracker
envsubst '${NS_DB}' \
  < "$MANIFESTS_DIR/configmap.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply CronJob
# =============================================================================

print_status "Applying cleanup CronJob..."
envsubst '${NS_DB} ${HEADSCALE_URL}' \
  < "$MANIFESTS_DIR/cronjob.yaml.tpl" | mt_apply kubectl apply -f -

print_success "Headscale cleanup CronJob deployed to $NS_DB"
echo "  Schedule: hourly at :15"
echo "  Manual trigger: kubectl create job --from=cronjob/headscale-cleanup test-cleanup -n $NS_DB"
