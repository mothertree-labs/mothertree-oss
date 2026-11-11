#!/bin/bash

# Deploy the tenant's Keycloak auth ingress (auth.<tenant host> -> shared Keycloak).
#
# Every app's OIDC login goes through this host, so it is a tenant prerequisite:
# create_env applies it right after the realm import, whichever apps the tenant
# has enabled. Each tenant owns its own Ingress object in NS_AUTH (rather than
# patching the Helm-managed Keycloak release), which avoids field-manager
# conflicts. deploy-matrix.sh and deploy-llm-webui.sh apply the same manifest
# for their standalone runs; applying it twice is a no-op.
#
# Usage:
#   ./apps/deploy-keycloak-tenant-ingress.sh -e <env> -t <tenant>

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  echo "Usage: $0 -e <env> -t <tenant>"
  echo ""
  echo "Apply the tenant's Keycloak auth ingress (AUTH_HOST -> shared Keycloak)."
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

mt_require_commands kubectl envsubst

: "${AUTH_HOST:?AUTH_HOST not set by config.sh}"
: "${NS_AUTH:?NS_AUTH not set by config.sh}"

print_status "Keycloak: applying tenant auth ingress keycloak-${TENANT} for $AUTH_HOST"
envsubst '${AUTH_HOST} ${TENANT} ${NS_AUTH} ${TENANT_DOMAIN} ${TENANT_NAME}' \
  < "$REPO_ROOT/apps/manifests/keycloak/tenant-auth-ingress.yaml.tpl" | kubectl apply -f -
print_success "Tenant auth ingress keycloak-${TENANT} applied"
