#!/bin/bash

# Deploy Admin Portal using static Kubernetes manifests
# This script applies environment-specific Admin Portal manifests using envsubst
#
# Namespace structure:
#   - Admin Portal in NS_ADMIN (tenant-prefixed namespace, e.g., 'tn-example-admin')
#
# Prerequisites:
#   - Keycloak deployed and accessible
#   - Tenant config and secrets must exist
#
# Usage:
#   ./apps/deploy-admin-portal.sh -e dev -t example

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy Admin Portal for a tenant."
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
mt_deploy_start "deploy-admin-portal"

mt_require_commands kubectl envsubst

print_status "Deploying Admin Portal for environment: $MT_ENV"
print_status "Tenant: $TENANT"
print_status "Admin namespace: $NS_ADMIN"

# Check if admin_portal_enabled feature flag is set
if [ "$ADMIN_PORTAL_ENABLED" != "true" ]; then
    print_warning "Admin Portal not enabled for tenant $TENANT (features.admin_portal_enabled is not true)"
    print_warning "Skipping Admin Portal deployment"
    exit 0
fi

# =============================================================================
# Secret Management
# =============================================================================
# K8s secret fallback for portal secrets.
# Priority: 1) value from secrets YAML (loaded by config.sh), 2) existing K8s secret, 3) generate new.
if [ -z "$ADMIN_PORTAL_OIDC_SECRET" ] || [ "$ADMIN_PORTAL_OIDC_SECRET" = "null" ] || [[ "$ADMIN_PORTAL_OIDC_SECRET" == *"PLACEHOLDER"* ]]; then
  ADMIN_PORTAL_OIDC_SECRET=$(read_k8s_secret "$NS_ADMIN" "admin-portal-secrets" "keycloak-client-secret")
  if [ -z "$ADMIN_PORTAL_OIDC_SECRET" ]; then
    print_warning "Admin Portal OIDC secret not configured, generating one..."
    ADMIN_PORTAL_OIDC_SECRET=$(openssl rand -base64 32)
  else
    print_status "Admin Portal OIDC secret: reusing existing value from cluster"
  fi
fi

if [ -z "$ADMIN_PORTAL_NEXTAUTH_SECRET" ] || [ "$ADMIN_PORTAL_NEXTAUTH_SECRET" = "null" ] || [[ "$ADMIN_PORTAL_NEXTAUTH_SECRET" == *"PLACEHOLDER"* ]]; then
  ADMIN_PORTAL_NEXTAUTH_SECRET=$(read_k8s_secret "$NS_ADMIN" "admin-portal-secrets" "nextauth-secret")
  if [ -z "$ADMIN_PORTAL_NEXTAUTH_SECRET" ]; then
    print_warning "Admin Portal NextAuth secret not configured, generating one..."
    ADMIN_PORTAL_NEXTAUTH_SECRET=$(openssl rand -base64 32)
  else
    print_status "Admin Portal NextAuth secret: reusing existing value from cluster"
  fi
fi

export ADMIN_PORTAL_OIDC_SECRET
export ADMIN_PORTAL_NEXTAUTH_SECRET

# Redis session password (shared between admin-portal and account-portal)
if [ -z "${REDIS_SESSION_PASSWORD:-}" ] || [ "$REDIS_SESSION_PASSWORD" = "null" ] || [[ "${REDIS_SESSION_PASSWORD:-}" == *"PLACEHOLDER"* ]]; then
  REDIS_SESSION_PASSWORD=$(read_k8s_secret "$NS_ADMIN" "admin-portal-secrets" "REDIS_PASSWORD")
  if [ -z "$REDIS_SESSION_PASSWORD" ]; then
    print_warning "Redis session password not configured, generating one..."
    REDIS_SESSION_PASSWORD=$(openssl rand -base64 24)
  else
    print_status "Redis session password: reusing existing value from cluster"
  fi
fi
export REDIS_SESSION_PASSWORD

# HMAC secret for beginSetup token (shared between admin-portal and account-portal)
if [ -z "${BEGINSETUP_SECRET:-}" ] || [ "$BEGINSETUP_SECRET" = "null" ] || [[ "${BEGINSETUP_SECRET:-}" == *"PLACEHOLDER"* ]]; then
  BEGINSETUP_SECRET=$(read_k8s_secret "$NS_ADMIN" "admin-portal-secrets" "beginsetup-secret")
  if [ -z "$BEGINSETUP_SECRET" ]; then
    print_warning "BeginSetup HMAC secret not configured, generating one..."
    BEGINSETUP_SECRET=$(openssl rand -base64 32)
  else
    print_status "BeginSetup secret: reusing existing value from cluster"
  fi
fi
export BEGINSETUP_SECRET

# Stalwart integration (device passwords / app passwords)
# NS_MAIL must point to the tenant mail namespace for the deployment template
export NS_MAIL="$NS_STALWART"

if [ -z "${STALWART_ADMIN_PASSWORD:-}" ] || [ "$STALWART_ADMIN_PASSWORD" = "null" ] || [[ "${STALWART_ADMIN_PASSWORD:-}" == *"PLACEHOLDER"* ]]; then
  print_warning "Stalwart admin password not configured - device passwords will not work"
fi

# =============================================================================
# DNS Record
# =============================================================================
print_status "Creating DNS record for tenant admin portal: $ADMIN_HOST"
DNS_RECORD_EXISTS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${TF_VAR_cloudflare_zone_id}/dns_records?name=${ADMIN_HOST}&type=A" \
  -H "Authorization: Bearer ${TF_VAR_cloudflare_api_token}" \
  -H "Content-Type: application/json" | jq -r '.result | length')

if [ "$DNS_RECORD_EXISTS" -gt 0 ]; then
  print_status "DNS record for $ADMIN_HOST already exists"
else
  INGRESS_IP=$(kubectl get svc -n "$NS_INGRESS" ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [ -n "$INGRESS_IP" ]; then
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${TF_VAR_cloudflare_zone_id}/dns_records" \
      -H "Authorization: Bearer ${TF_VAR_cloudflare_api_token}" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"${ADMIN_HOST}\",\"content\":\"${INGRESS_IP}\",\"ttl\":300,\"proxied\":false}" > /dev/null
    print_status "DNS record created for $ADMIN_HOST -> $INGRESS_IP"
  else
    print_warning "Could not get ingress IP, DNS record not created"
  fi
fi

# =============================================================================
# Image Tags & Release Version
# =============================================================================
source "${REPO_ROOT}/scripts/lib/image-tags.sh"
_mt_load_image_tags
print_status "Admin Portal image: $ADMIN_PORTAL_IMAGE"

source "${REPO_ROOT}/scripts/lib/release.sh"
_mt_load_release_version
print_status "Release version: $RELEASE_VERSION"

# =============================================================================
# Deploy Manifests
# =============================================================================
print_status "Deploying admin portal manifests..."

# Apply secrets FIRST
envsubst < "$REPO_ROOT/apps/manifests/admin-portal/secrets.yaml.tpl" | kubectl apply -n "$NS_ADMIN" -f -

# Deploy Redis for session storage
print_status "Deploying Redis for session storage to $NS_ADMIN namespace..."
kubectl apply -n "$NS_ADMIN" -f "$REPO_ROOT/apps/manifests/admin-portal/redis.yaml"
kubectl wait --for=condition=available deployment/redis -n "$NS_ADMIN" --timeout=60s || {
  print_warning "Redis may not be fully ready yet"
}

# Apply service
kubectl apply -n "$NS_ADMIN" -f "$REPO_ROOT/apps/manifests/admin-portal/service.yaml"

# Apply ingress
envsubst < "$REPO_ROOT/apps/manifests/admin-portal/ingress.yaml.tpl" | kubectl apply -n "$NS_ADMIN" -f -

# Apply deployment
envsubst < "$REPO_ROOT/apps/manifests/admin-portal/deployment.yaml.tpl" | kubectl apply -n "$NS_ADMIN" -f -

# Deploy HPA for admin-portal auto-scaling
envsubst < "$REPO_ROOT/apps/manifests/admin-portal/admin-portal-hpa.yaml.tpl" | kubectl apply -n "$NS_ADMIN" -f -
print_status "Admin Portal HPA deployed (CPU 80% threshold)"

# Restart ALL secret consumers together to ensure password consistency.
print_status "Restarting Redis and Admin Portal to pick up secrets..."
kubectl rollout restart deployment/redis -n "$NS_ADMIN"
kubectl rollout status deployment/redis -n "$NS_ADMIN" --timeout=60s || {
  print_warning "Redis may not be fully ready yet"
}
kubectl rollout restart deployment/admin-portal -n "$NS_ADMIN"

# Wait for deployment to be ready
print_status "Waiting for Admin Portal deployment..."
kubectl rollout status deployment/admin-portal -n "$NS_ADMIN" --timeout=120s || {
  print_warning "Admin Portal deployment may not be fully ready"
}

print_status "Admin Portal deployed to https://$ADMIN_HOST"

# =============================================================================
# Setup Keycloak OIDC clients (idempotent)
# =============================================================================
print_status "Setting up portal OIDC clients in Keycloak..."
"$REPO_ROOT/scripts/setup-admin-portal-client" -e "$MT_ENV" -t "$MT_TENANT" || {
  print_warning "Failed to setup portal clients - may need manual configuration"
}
