#!/bin/bash

# Deploy Tailscale Key Rotator CronJob
# Purpose: Deploy a K8s CronJob that keeps every Tailscale-sidecar auth Secret
#          holding a valid key: it reads the key each Secret holds, looks it up
#          on Headscale via the REST API (by redacted prefix), and when the key
#          is missing, single-use, untagged, expired or close to expiry it mints
#          a tagged replacement, patches the Secret, restarts the Deployment and
#          proves the sidecar authenticated.
#
# Creates:
#   - ServiceAccount + namespace-scoped Roles/RoleBindings (infra-db,
#     infra-ingress-internal, infra-monitoring)
#   - Secret (Headscale API key)
#   - ConfigMap (components.conf + rotate.sh + scripts/lib/tailscale-keys.sh,
#     the same library the deploy scripts use)
#   - CronJob (daily, 04:00 UTC)
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
LIB_FILE="$REPO_ROOT/scripts/lib/tailscale-keys.sh"

# =============================================================================
# Validate required config
# =============================================================================

: "${HEADSCALE_URL:?HEADSCALE_URL not set. Add headscale.url to infra config.}"
export HEADSCALE_URL

# The rotator is what keeps the mesh alive across pod recreation; it is not
# optional. Create the key on the Headscale VM: headscale apikeys create --expiration 87600h
: "${TAILSCALE_ROTATOR_API_KEY:?tailscale.rotator_api_key not set in infra secrets — required for the key rotator (headscale apikeys create --expiration 87600h)}"
export TAILSCALE_ROTATOR_API_KEY

export NS_DB NS_INGRESS_INTERNAL NS_MONITORING

print_status "Deploying Tailscale key rotator to $NS_DB (env: $MT_ENV)"
print_status "  Headscale URL: $HEADSCALE_URL"

# =============================================================================
# Apply RBAC
# =============================================================================

print_status "Applying key rotator RBAC..."
mt_reset_change_tracker
envsubst '${NS_DB} ${NS_INGRESS_INTERNAL} ${NS_MONITORING}' \
  < "$MANIFESTS_DIR/rbac.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply Secret (API key)
# =============================================================================

print_status "Applying rotator API key secret..."
envsubst '${NS_DB} ${TAILSCALE_ROTATOR_API_KEY}' \
  < "$MANIFESTS_DIR/secret.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply ConfigMap (component list + driver + shared library)
# =============================================================================

print_status "Applying key rotator ConfigMap..."
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
envsubst '${NS_DB} ${NS_INGRESS_INTERNAL} ${NS_MONITORING}' \
  < "$MANIFESTS_DIR/components.conf.tpl" > "$WORK_DIR/components.conf"

kubectl create configmap tailscale-rotator-config -n "$NS_DB" \
  --from-file=components.conf="$WORK_DIR/components.conf" \
  --from-file=rotate.sh="$MANIFESTS_DIR/rotate.sh" \
  --from-file=tailscale-keys.sh="$LIB_FILE" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - app=tailscale-key-rotator --dry-run=client -o yaml \
  | mt_apply kubectl apply -f -

# =============================================================================
# Apply CronJob
# =============================================================================

print_status "Applying key rotator CronJob..."
envsubst '${NS_DB} ${HEADSCALE_URL}' \
  < "$MANIFESTS_DIR/cronjob.yaml.tpl" | mt_apply kubectl apply -f -

print_success "Tailscale key rotator deployed to $NS_DB"
echo "  Schedule: daily (04:00 UTC)"
echo "  Manual run:  kubectl create job --from=cronjob/tailscale-key-rotator rotate-now -n $NS_DB"
echo "  From a laptop: ./scripts/check-tailscale-keys -e $MT_ENV [--rotate]"
