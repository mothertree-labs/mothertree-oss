#!/bin/bash

# Deploy Home Page Application
# This script deploys the home page switcher application to Kubernetes
#
# Prerequisites:
#   - Environment variables must be set (by create_env or manually):
#     HOME_HOST, DOCS_HOST, MATRIX_HOST, TENANT_NAME, TENANT_DISPLAY_NAME
#   - Kubeconfig must be available

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Configuration
MT_ENV=${MT_ENV:-prod}
if [ -z "${TENANT:-}" ]; then
    print_error "TENANT is not set. Usage: MT_ENV=dev TENANT=example ./apps/deploy-home.sh"
    exit 1
fi
REPO_ROOT="${REPO_ROOT:-/workspace}"

export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/kubeconfig.$MT_ENV.yaml}"

# Validate kubeconfig exists
if [ ! -f "$KUBECONFIG" ]; then
    print_error "Kubeconfig not found: $KUBECONFIG"
    print_error "Please run phase1 deployment first or set KUBECONFIG."
    exit 1
fi

# Validate required environment variables
required_vars=("HOME_HOST" "DOCS_HOST" "MATRIX_HOST" "TENANT_NAME")
missing_vars=()
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -gt 0 ]; then
    print_error "Required environment variables not set: ${missing_vars[*]}"
    print_error "This script should be called from create_env which sets these from tenant config."
    print_error "Or set them manually: HOME_HOST=home.example.org DOCS_HOST=docs.example.org ..."
    exit 1
fi

# Set defaults for optional vars
export NS_HOME="${NS_HOME:-home}"
export TENANT_DISPLAY_NAME="${TENANT_DISPLAY_NAME:-$TENANT_NAME}"

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
print_status "Deploying home page components..."
cat "$REPO_ROOT/apps/templates/home/namespace.yaml" | sed "s/namespace: home/namespace: $NS_HOME/g" | kubectl apply -f -
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
EXTERNAL_IP=$(kubectl get service -n "${NS_INGRESS:-infra-ingress}" ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "unknown")
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
