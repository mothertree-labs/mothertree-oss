#!/bin/bash

# Complete Home Page Deployment Script
# This script deploys the home page switcher and applies all necessary configurations
#
# Prerequisites:
#   - Environment variables must be set (by create_env or manually):
#     HOME_HOST, DOCS_HOST, MATRIX_HOST, TENANT_NAME, TENANT_DISPLAY_NAME
#   - Kubeconfig must be available

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/workspace}"
MT_ENV=${MT_ENV:-prod}

export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/kubeconfig.$MT_ENV.yaml}"

# Check if kubeconfig exists
if [ ! -f "$KUBECONFIG" ]; then
    echo "❌ Error: $KUBECONFIG not found. Please run phase1 deployment first."
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
    echo "❌ Required environment variables not set: ${missing_vars[*]}"
    echo "This script should be called from create_env which sets these from tenant config."
    exit 1
fi

# Set defaults
NS_HOME="${NS_HOME:-home}"
NS_MATRIX="${NS_MATRIX:-tn-${TENANT_NAME:-example}-matrix}"
export TENANT_DISPLAY_NAME="${TENANT_DISPLAY_NAME:-$TENANT_NAME}"

echo "🏠 Deploying Complete Home Page Application..."
echo "Environment: $MT_ENV, Tenant: $TENANT_NAME"
echo "Home URL: https://$HOME_HOST"

# 1. Deploy home page application using the updated deploy-home.sh
echo "📦 Deploying home page application..."
cd "$REPO_ROOT/apps"
./deploy-home.sh

# 2. Update element-web Helm release with iframe-friendly headers
echo "🔧 Configuring matrix ingress for iframe embedding..."
cd "$REPO_ROOT/apps"
# Use sync instead of apply to skip slow diff operation
helmfile -e "$MT_ENV" -l name=element-web sync

# 3. Wait for deployment to be ready
echo "⏳ Waiting for deployment to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/home-page -n "$NS_HOME" || echo "⚠️ Deployment may not be ready yet"

# 4. Check certificate status
echo "🔍 Checking SSL certificate status..."
kubectl get certificates -n "$NS_HOME" 2>/dev/null || echo "No certificates found yet"

# 5. Verify iframe headers
echo "🔍 Verifying iframe headers..."
echo "Docs headers:"
curl -I "https://$DOCS_HOST" 2>/dev/null | grep -i "x-frame-options\|content-security-policy" || echo "Headers not yet applied"

echo "Matrix headers:"
curl -I "https://$MATRIX_HOST" 2>/dev/null | grep -i "x-frame-options\|content-security-policy" || echo "Headers not yet applied"

echo ""
echo "✅ Complete home page deployment finished!"
echo ""
echo "🌐 Access your home page at: https://$HOME_HOST"
echo "📱 Features:"
echo "   - Persistent navigation bar with Docs and Matrix buttons"
echo "   - Lazy loading for better performance"
echo "   - Mobile-responsive design"
echo "   - Keyboard shortcuts (Ctrl+1 for Docs, Ctrl+2 for Matrix)"
echo ""
echo "🔧 To check deployment status:"
echo "   kubectl get pods -n $NS_HOME"
echo "   kubectl get ingress -n $NS_HOME"
echo ""
echo "📝 To view logs:"
echo "   kubectl logs -f deployment/home-page -n $NS_HOME"
