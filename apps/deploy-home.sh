#!/bin/bash

# Deploy Home Page Application
# This script deploys the home page switcher application to Kubernetes
#
# Usage:
#   ./apps/deploy-home.sh -e dev -t example

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy Home Page Application for a tenant."
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

print_status "Deploying Home Page Application..."
print_status "Environment: $MT_ENV"
print_status "Tenant: $TENANT_NAME"
print_status "Home URL: https://$HOME_HOST"
print_status "Docs URL: https://$DOCS_HOST"
print_status "Matrix URL: https://$MATRIX_HOST"

# Create namespace
print_status "Creating namespace..."
kubectl create namespace "$NS_HOME" --dry-run=client -o yaml | kubectl apply -f -

# Apply non-templated manifests with namespace substitution
# (namespace.yaml is skipped — line above already creates the namespace)
print_status "Deploying home page components..."
cat "$REPO_ROOT/apps/templates/home/nginx-config.yaml" | sed "s/namespace: home/namespace: $NS_HOME/g" | kubectl apply -f -
cat "$REPO_ROOT/apps/templates/home/deployment.yaml" | sed "s/namespace: home/namespace: $NS_HOME/g" | kubectl apply -f -
cat "$REPO_ROOT/apps/templates/home/service.yaml" | sed "s/namespace: home/namespace: $NS_HOME/g" | kubectl apply -f -

# Apply templated manifests with envsubst
print_status "Applying templated manifests..."
envsubst < "$REPO_ROOT/apps/templates/home/configmap.yaml.tpl" | kubectl apply -f -
envsubst < "$REPO_ROOT/apps/templates/home/ingress.yaml.tpl" | kubectl apply -f -

# Wait for deployment to be ready
print_status "Waiting for deployment to be ready..."
if kubectl wait --for=condition=available --timeout=300s deployment/home-page -n "$NS_HOME"; then
    print_success "Deployment ready"
else
    print_warning "Deployment may not be fully ready"
fi

# Check ingress status
print_status "Checking ingress status..."
kubectl get ingress home-page -n "$NS_HOME"

# Get the external IP
print_status "Getting external IP..."
EXTERNAL_IP=$(kubectl get service -n "$NS_INGRESS" ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "unknown")
echo "External IP: $EXTERNAL_IP"

# Check DNS propagation
print_status "Checking DNS propagation for $HOME_HOST..."
nslookup "$HOME_HOST" || print_warning "DNS may not be propagated yet. This is normal for new records."

echo ""
print_success "Home page deployment completed!"
echo ""
echo "Access your home page at: https://$HOME_HOST"
echo "The page includes:"
echo "   - Persistent navigation bar with Docs and Matrix buttons"
echo "   - Lazy loading for better performance"
echo "   - Mobile-responsive design"
echo "   - Keyboard shortcuts (Ctrl+1 for Docs, Ctrl+2 for Matrix)"
echo ""
echo "To check deployment status:"
echo "   kubectl get pods -n $NS_HOME"
echo "   kubectl get ingress -n $NS_HOME"
echo ""
echo "To view logs:"
echo "   kubectl logs -f deployment/home-page -n $NS_HOME"
