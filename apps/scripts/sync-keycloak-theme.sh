#!/bin/bash

# Script to sync Keycloak MotherTree theme from repo to ConfigMap and restart pod
# This enables rapid iteration on theme changes without full Helmfile deployments
#
# Usage: MT_ENV=dev ./apps/scripts/sync-keycloak-theme.sh
#        MT_ENV=prod ./apps/scripts/sync-keycloak-theme.sh

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

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Require MT_ENV and set kubeconfig
REPO_ROOT="${REPO_ROOT:-/workspace}"
if [ -z "${MT_ENV:-}" ]; then
  print_error "MT_ENV is not set. Usage: MT_ENV=dev ./apps/scripts/sync-keycloak-theme.sh"
  exit 1
fi

export KUBECONFIG="$REPO_ROOT/kubeconfig.$MT_ENV.yaml"

# Use namespace variable from environment, default to infra-auth
NS_AUTH="${NS_AUTH:-infra-auth}"

# Verify theme directory exists
THEME_DIR="$REPO_ROOT/apps/themes/platform"
if [ ! -d "$THEME_DIR" ]; then
    print_error "Theme directory not found: $THEME_DIR"
    exit 1
fi

print_status "Syncing MotherTree theme to ConfigMap (env=$MT_ENV)..."

# Delete existing ConfigMap if it exists (ConfigMaps are immutable when using --from-directory)
print_status "Removing existing ConfigMap (if any)..."
kubectl -n "$NS_AUTH" delete configmap keycloak-platform-theme 2>/dev/null || true

# Create ConfigMap from theme directory
# ConfigMap keys can't contain slashes, so we'll create a tar.gz and extract it via init container
# Or mount at /opt/keycloak/themes/platform and use valid keys with underscores
print_status "Creating ConfigMap from theme directory..."
cd "$(dirname "$THEME_DIR")"  # Change to themes directory (parent of platform)

# Create a tar.gz of the theme directory and store it in ConfigMap
print_status "Packaging theme directory..."
TMP_TAR=$(mktemp)
tar -czf "$TMP_TAR" platform

# Create ConfigMap with the tar.gz file
kubectl -n "$NS_AUTH" create configmap keycloak-platform-theme \
    --from-file=theme.tar.gz="$TMP_TAR" \
    --dry-run=client -o yaml | kubectl apply -f -

rm -f "$TMP_TAR"
cd - > /dev/null

if [ $? -eq 0 ]; then
    print_success "ConfigMap 'keycloak-platform-theme' created/updated"
else
    print_error "Failed to create ConfigMap"
    exit 1
fi

# Get Keycloak StatefulSet name
STATEFULSET_NAME=$(kubectl -n "$NS_AUTH" get statefulset -l app.kubernetes.io/name=keycloakx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$STATEFULSET_NAME" ]; then
    print_error "Keycloak StatefulSet not found in namespace '$NS_AUTH'"
    exit 1
fi

print_status "Restarting Keycloak pod to pick up theme changes..."
kubectl -n "$NS_AUTH" rollout restart statefulset/"$STATEFULSET_NAME"

print_status "Waiting for Keycloak pod to be ready..."
kubectl -n "$NS_AUTH" rollout status statefulset/"$STATEFULSET_NAME" --timeout=300s

if [ $? -eq 0 ]; then
    print_success "Keycloak pod restarted and ready"
    print_status "Theme changes should now be visible at:"
    echo "  https://${AUTH_HOST:-auth.\$TENANT_DOMAIN}/realms/${TENANT_KEYCLOAK_REALM:-docs}/account"
else
    print_error "Keycloak pod failed to become ready"
    exit 1
fi
