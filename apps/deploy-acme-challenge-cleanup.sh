#!/bin/bash

# Deploy ACME challenge cleanup CronJob
# Purpose: Deploy a K8s CronJob that prunes orphaned cert-manager DNS-01
#          `_acme-challenge.*` TXT records from the infra Cloudflare zone.
#
#          cert-manager creates these TXT records during DNS-01 validation and
#          removes them once solved. Clusters torn down mid-challenge (notably
#          the ephemeral dev clusters, which share the same zone) orphan them.
#          Left unchecked they fill the zone's record quota and cert-manager
#          starts failing renewals with Cloudflare error 81045.
#
#          Reuses the `cloudflare-api-token` secret already created in
#          infra-cert-manager by deploy_infra — no new secret, no RBAC.
#
# Creates:
#   - ConfigMap (prune script)
#   - CronJob (hourly at :40)
#
# Called by: deploy_infra
# Can also be run standalone.
#
# Usage:
#   ./apps/deploy-acme-challenge-cleanup.sh -e <env>

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  echo "Usage: $0 -e <env>"
  echo ""
  echo "Deploy the ACME challenge cleanup CronJob to the infra-cert-manager namespace."
  echo ""
  echo "Options:"
  echo "  -e <env>       Environment (e.g., dev, prod)"
  echo "  -h, --help     Show this help"
}

mt_parse_args "$@"
mt_require_env

# Load infrastructure configuration (sets NS_CERTMANAGER, INFRA_DOMAIN)
source "${REPO_ROOT}/scripts/lib/infra-config.sh"
mt_load_infra_config

mt_require_commands kubectl envsubst

MANIFESTS_DIR="$REPO_ROOT/apps/manifests/acme-challenge-cleanup"

# =============================================================================
# Validate required config
# =============================================================================

: "${NS_CERTMANAGER:?NS_CERTMANAGER not set}"
: "${INFRA_DOMAIN:?INFRA_DOMAIN not set — cannot determine the Cloudflare zone to prune}"
export NS_CERTMANAGER INFRA_DOMAIN

# The CronJob reads the Cloudflare token from the `cloudflare-api-token` secret
# that deploy_infra creates in this namespace. Fail loudly if it is absent — the
# job would otherwise deploy but never be able to start (secretKeyRef unresolved).
if ! kubectl get secret cloudflare-api-token -n "$NS_CERTMANAGER" >/dev/null 2>&1; then
  print_error "Secret 'cloudflare-api-token' not found in $NS_CERTMANAGER."
  print_error "It is created by deploy_infra during cert-manager setup — run that first."
  exit 1
fi

print_status "Deploying ACME challenge cleanup CronJob to $NS_CERTMANAGER (env: $MT_ENV)"
print_status "  Zone: $INFRA_DOMAIN"

# =============================================================================
# Apply ConfigMap (prune script)
# =============================================================================

print_status "Applying cleanup ConfigMap..."
mt_reset_change_tracker
envsubst '${NS_CERTMANAGER}' \
  < "$MANIFESTS_DIR/configmap.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply CronJob
# =============================================================================

print_status "Applying cleanup CronJob..."
envsubst '${NS_CERTMANAGER} ${INFRA_DOMAIN}' \
  < "$MANIFESTS_DIR/cronjob.yaml.tpl" | mt_apply kubectl apply -f -

print_success "ACME challenge cleanup CronJob deployed to $NS_CERTMANAGER"
echo "  Schedule: hourly at :40"
echo "  Manual trigger: kubectl create job --from=cronjob/acme-challenge-cleanup acme-cleanup-test -n $NS_CERTMANAGER"
