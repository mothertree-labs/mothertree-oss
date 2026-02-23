#!/bin/bash

# Complete Home Page Deployment Script
# This script deploys the home page switcher and applies all necessary configurations
#
# Usage:
#   ./apps/deploy-home-complete.sh -e dev -t example

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Complete Home Page deployment for a tenant."
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

mt_require_commands kubectl helm helmfile

print_status "Deploying Complete Home Page Application..."
print_status "Environment: $MT_ENV, Tenant: $TENANT_NAME"
print_status "Home URL: https://$HOME_HOST"

# 1. Deploy home page application using the updated deploy-home.sh
print_status "Deploying home page application..."
"$REPO_ROOT/apps/deploy-home.sh" -e "$MT_ENV" -t "$MT_TENANT"

# 2. Update element-web Helm release with iframe-friendly headers
print_status "Configuring matrix ingress for iframe embedding..."
pushd "$REPO_ROOT/apps" >/dev/null
  # Use sync instead of apply to skip slow diff operation
  helmfile -e "$MT_ENV" -l name=element-web sync
popd >/dev/null

# 3. Wait for deployment to be ready
print_status "Waiting for deployment to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/home-page -n "$NS_HOME" || print_warning "Deployment may not be ready yet"

# 4. Check certificate status
print_status "Checking SSL certificate status..."
kubectl get certificates -n "$NS_HOME" 2>/dev/null || echo "No certificates found yet"

# 5. Verify iframe headers
print_status "Verifying iframe headers..."
echo "Docs headers:"
curl -I "https://$DOCS_HOST" 2>/dev/null | grep -i "x-frame-options\|content-security-policy" || echo "Headers not yet applied"

echo "Matrix headers:"
curl -I "https://$MATRIX_HOST" 2>/dev/null | grep -i "x-frame-options\|content-security-policy" || echo "Headers not yet applied"

echo ""
print_success "Complete home page deployment finished!"
echo ""
echo "Access your home page at: https://$HOME_HOST"
echo ""
echo "To check deployment status:"
echo "   kubectl get pods -n $NS_HOME"
echo "   kubectl get ingress -n $NS_HOME"
echo ""
echo "To view logs:"
echo "   kubectl logs -f deployment/home-page -n $NS_HOME"
