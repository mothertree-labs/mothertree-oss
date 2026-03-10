#!/bin/bash

# Deploy Account Portal using static Kubernetes manifests
# This script applies environment-specific Account Portal manifests using envsubst
#
# Namespace structure:
#   - Account Portal in NS_ADMIN (tenant-prefixed namespace, e.g., 'tn-example-admin')
#
# Prerequisites:
#   - Keycloak deployed and accessible
#   - Admin Portal deployed (shares Redis and namespace)
#   - Tenant config and secrets must exist
#
# Usage:
#   ./apps/deploy-account-portal.sh -e dev -t example

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy Account Portal for a tenant."
    echo ""
    echo "Options:"
    echo "  -e <env>       Environment (e.g., dev, prod)"
    echo "  -t <tenant>    Tenant name (e.g., example)"
    echo "  -h, --help     Show this help"
}

mt_parse_args "$@"
mt_require_env
mt_require_tenant

source "${REPO_ROOT}/scripts/lib/config.sh"
mt_load_tenant_config

source "${REPO_ROOT}/scripts/lib/paths.sh"
_mt_resolve_project_conf
[[ -n "$MT_PROJECT_CONF" ]] && source "$MT_PROJECT_CONF"

source "${REPO_ROOT}/scripts/lib/notify.sh"
mt_deploy_start "deploy-account-portal"

mt_require_commands kubectl envsubst

print_status "Deploying Account Portal for environment: $MT_ENV"
print_status "Tenant: $TENANT"
print_status "Admin namespace: $NS_ADMIN"

# Check if account_portal_enabled feature flag is set
if [ "$ACCOUNT_PORTAL_ENABLED" != "true" ]; then
    print_warning "Account Portal not enabled for tenant $TENANT (features.account_portal_enabled is not true)"
    print_warning "Skipping Account Portal deployment"
    exit 0
fi

# =============================================================================
# Secret Management
# =============================================================================
# K8s secret fallback for account portal secrets
if [ -z "$ACCOUNT_PORTAL_OIDC_SECRET" ] || [ "$ACCOUNT_PORTAL_OIDC_SECRET" = "null" ] || [[ "$ACCOUNT_PORTAL_OIDC_SECRET" == *"PLACEHOLDER"* ]]; then
  ACCOUNT_PORTAL_OIDC_SECRET=$(read_k8s_secret "$NS_ADMIN" "account-portal-secrets" "keycloak-client-secret")
  if [ -z "$ACCOUNT_PORTAL_OIDC_SECRET" ]; then
    print_error "Account Portal OIDC secret not configured in $TENANT_SECRETS and not found in cluster"
    print_error "Add 'account_portal_client_secret' under the 'oidc' section"
    exit 1
  else
    print_status "Account Portal OIDC secret: reusing existing value from cluster"
  fi
fi

if [ -z "$ACCOUNT_PORTAL_NEXTAUTH_SECRET" ] || [ "$ACCOUNT_PORTAL_NEXTAUTH_SECRET" = "null" ] || [[ "$ACCOUNT_PORTAL_NEXTAUTH_SECRET" == *"PLACEHOLDER"* ]]; then
  ACCOUNT_PORTAL_NEXTAUTH_SECRET=$(read_k8s_secret "$NS_ADMIN" "account-portal-secrets" "nextauth-secret")
  if [ -z "$ACCOUNT_PORTAL_NEXTAUTH_SECRET" ]; then
    print_warning "Account Portal session secret not configured, generating one..."
    ACCOUNT_PORTAL_NEXTAUTH_SECRET=$(openssl rand -base64 32)
  else
    print_status "Account Portal session secret: reusing existing value from cluster"
  fi
fi

# Guest provisioning API key (used by Nextcloud guest_bridge to create guest users)
if [ -z "${GUEST_PROVISIONING_API_KEY:-}" ] || [ "$GUEST_PROVISIONING_API_KEY" = "null" ] || [[ "${GUEST_PROVISIONING_API_KEY:-}" == *"PLACEHOLDER"* ]]; then
  GUEST_PROVISIONING_API_KEY=$(read_k8s_secret "$NS_ADMIN" "account-portal-secrets" "guest-provisioning-api-key")
  if [ -z "$GUEST_PROVISIONING_API_KEY" ]; then
    print_warning "Guest provisioning API key not configured, generating one..."
    GUEST_PROVISIONING_API_KEY=$(openssl rand -base64 32)
  else
    print_status "Guest provisioning API key: reusing existing value from cluster"
  fi
fi

export ACCOUNT_PORTAL_OIDC_SECRET
export ACCOUNT_PORTAL_NEXTAUTH_SECRET
export GUEST_PROVISIONING_API_KEY

# NS_MAIL must point to the tenant mail namespace for the deployment template
export NS_MAIL="$NS_STALWART"

# =============================================================================
# Image Tags & Release Version
# =============================================================================
source "${REPO_ROOT}/scripts/lib/image-tags.sh"
_mt_load_image_tags
print_status "Account Portal image: $ACCOUNT_PORTAL_IMAGE"

source "${REPO_ROOT}/scripts/lib/release.sh"
_mt_load_release_version
print_status "Release version: $RELEASE_VERSION"

# =============================================================================
# Deploy Manifests
# =============================================================================
print_status "Deploying account portal manifests..."

# Apply secrets
envsubst < "$REPO_ROOT/apps/manifests/account-portal/secrets.yaml.tpl" | kubectl apply -n "$NS_ADMIN" -f -

# Apply service
kubectl apply -n "$NS_ADMIN" -f "$REPO_ROOT/apps/manifests/account-portal/service.yaml"

# Apply ingress
envsubst < "$REPO_ROOT/apps/manifests/account-portal/ingress.yaml.tpl" | kubectl apply -n "$NS_ADMIN" -f -

# Apply deployment
envsubst < "$REPO_ROOT/apps/manifests/account-portal/deployment.yaml.tpl" | kubectl apply -n "$NS_ADMIN" -f -

# Deploy HPA for account-portal auto-scaling
envsubst < "$REPO_ROOT/apps/manifests/account-portal/account-portal-hpa.yaml.tpl" | kubectl apply -n "$NS_ADMIN" -f -
print_status "Account Portal HPA deployed (CPU 80% threshold)"

# Restart to pick up any secret or image changes
print_status "Restarting Account Portal deployment..."
kubectl rollout restart deployment/account-portal -n "$NS_ADMIN"

# Wait for deployment to be ready
print_status "Waiting for Account Portal deployment..."
kubectl rollout status deployment/account-portal -n "$NS_ADMIN" --timeout=120s || {
  print_warning "Account Portal deployment may not be fully ready"
}

print_status "Account Portal deployed to https://$ACCOUNT_HOST"
