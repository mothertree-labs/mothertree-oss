#!/bin/bash

# Migration script: Move from old namespace structure to tenant-prefixed namespaces
#
# OLD STRUCTURE:
#   - matrix (Synapse, Element, Jitsi)
#   - docs (PostgreSQL, Redis, Keycloak, backend, frontend)
#   - files (Nextcloud)
#   - monitoring, ingress-nginx, ingress-internal, cert-manager, mail
#
# NEW STRUCTURE:
#   Infrastructure (infra-*):
#     - infra-db (PostgreSQL - shared)
#     - infra-auth (Keycloak - shared)
#     - infra-monitoring, infra-ingress, infra-ingress-internal, infra-cert-manager, infra-mail
#
#   Tenant (tn-<tenant>-*):
#     - tn-example-matrix (Synapse, Element)
#     - tn-example-jitsi (Jitsi components)
#     - tn-example-docs (Docs backend, frontend, y-provider, Redis)
#     - tn-example-files (Nextcloud)
#
# This script helps clean up the old resources before redeploying with the new structure.
# It preserves PVCs (data) by default.

set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TENANT="${1:-example}"
MT_ENV="${2:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ -z "$MT_ENV" ]; then
    echo "Usage: $0 <tenant> <env>"
    echo ""
    echo "This script migrates from old namespace structure to tenant-prefixed namespaces."
    echo ""
    echo "Example: $0 example prod"
    echo ""
    echo "WARNING: This will DELETE deployments, services, and other resources."
    echo "         PVCs (persistent data) are preserved by default."
    exit 1
fi

export KUBECONFIG="$REPO/kubeconfig.$MT_ENV.yaml"

if [ ! -f "$KUBECONFIG" ]; then
    print_error "Kubeconfig not found: $KUBECONFIG"
    exit 1
fi

print_status "Migration script for tenant: $TENANT, environment: $MT_ENV"
print_warning "This will delete deployments and services from old namespaces."
print_warning "PVCs (data) will be preserved."
echo ""

# Confirm
read -p "Type 'migrate' to proceed: " confirm
if [ "$confirm" != "migrate" ]; then
    print_error "Migration cancelled."
    exit 1
fi

echo ""
print_status "Step 1: Uninstall Helm releases from old namespaces"

# Uninstall matrix releases
for release in matrix-synapse element-web; do
    if helm status "$release" -n matrix >/dev/null 2>&1; then
        print_status "Uninstalling $release from matrix namespace..."
        helm uninstall "$release" -n matrix || print_warning "Failed to uninstall $release"
    else
        print_status "$release not found in matrix namespace (already removed or never installed)"
    fi
done

# Uninstall docs releases
for release in keycloak docs-redis docs-postgresql; do
    if helm status "$release" -n docs >/dev/null 2>&1; then
        print_status "Uninstalling $release from docs namespace..."
        helm uninstall "$release" -n docs || print_warning "Failed to uninstall $release"
    else
        print_status "$release not found in docs namespace"
    fi
done

# Uninstall files releases
for release in nextcloud; do
    if helm status "$release" -n files >/dev/null 2>&1; then
        print_status "Uninstalling $release from files namespace..."
        helm uninstall "$release" -n files || print_warning "Failed to uninstall $release"
    else
        print_status "$release not found in files namespace"
    fi
done

# Uninstall system releases from old namespaces
for release in ingress-nginx; do
    if helm status "$release" -n ingress-nginx >/dev/null 2>&1; then
        print_status "Uninstalling $release from ingress-nginx namespace..."
        helm uninstall "$release" -n ingress-nginx || print_warning "Failed to uninstall $release"
    fi
done

for release in ingress-nginx-internal; do
    if helm status "$release" -n ingress-internal >/dev/null 2>&1; then
        print_status "Uninstalling $release from ingress-internal namespace..."
        helm uninstall "$release" -n ingress-internal || print_warning "Failed to uninstall $release"
    fi
done

for release in cert-manager; do
    if helm status "$release" -n cert-manager >/dev/null 2>&1; then
        print_status "Uninstalling $release from cert-manager namespace..."
        helm uninstall "$release" -n cert-manager || print_warning "Failed to uninstall $release"
    fi
done

for release in kube-prometheus-stack vector; do
    if helm status "$release" -n monitoring >/dev/null 2>&1; then
        print_status "Uninstalling $release from monitoring namespace..."
        helm uninstall "$release" -n monitoring || print_warning "Failed to uninstall $release"
    fi
done

echo ""
print_status "Step 2: Delete non-Helm resources from old namespaces"

# Delete Jitsi resources from matrix namespace
print_status "Deleting Jitsi resources from matrix namespace..."
kubectl delete deployment jitsi-web jitsi-jvb jitsi-jicofo jitsi-keycloak-adapter -n matrix --ignore-not-found=true || true
kubectl delete statefulset jitsi-prosody -n matrix --ignore-not-found=true || true
kubectl delete service jitsi-web jitsi-jvb jitsi-prosody jitsi-jicofo jitsi-keycloak-adapter -n matrix --ignore-not-found=true || true
kubectl delete configmap jitsi-web-config jitsi-keycloak-adapter-static meet-conf-template -n matrix --ignore-not-found=true || true
kubectl delete secret jitsi-secrets -n matrix --ignore-not-found=true || true
kubectl delete ingress jitsi-ingress -n matrix --ignore-not-found=true || true

# Delete docs app resources (but not PostgreSQL data)
print_status "Deleting Docs application resources from docs namespace..."
kubectl delete deployment backend frontend docs-y-provider redis -n docs --ignore-not-found=true || true
kubectl delete service backend frontend y-provider redis -n docs --ignore-not-found=true || true
kubectl delete configmap docs-config storage-backends-config save-status-config yprovider-config health-sidecar-config -n docs --ignore-not-found=true || true
kubectl delete secret docs-secrets -n docs --ignore-not-found=true || true
kubectl delete ingress docs-ingress -n docs --ignore-not-found=true || true
kubectl delete job docs-migrations docs-db-init -n docs --ignore-not-found=true || true

# Delete synapse-admin from matrix namespace (managed by Terraform)
print_status "Deleting synapse-admin from matrix namespace..."
kubectl delete deployment synapse-admin -n matrix --ignore-not-found=true || true
kubectl delete service synapse-admin -n matrix --ignore-not-found=true || true
kubectl delete configmap synapse-admin-config -n matrix --ignore-not-found=true || true
kubectl delete ingress synapse-admin -n matrix --ignore-not-found=true || true

echo ""
print_status "Step 3: Create new namespaces"

# Infrastructure namespaces (infra-*)
print_status "Creating infrastructure namespaces..."
kubectl create namespace "infra-db" 2>/dev/null || print_status "infra-db namespace already exists"
kubectl create namespace "infra-auth" 2>/dev/null || print_status "infra-auth namespace already exists"
kubectl create namespace "infra-monitoring" 2>/dev/null || print_status "infra-monitoring namespace already exists"
kubectl create namespace "infra-ingress" 2>/dev/null || print_status "infra-ingress namespace already exists"
kubectl create namespace "infra-ingress-internal" 2>/dev/null || print_status "infra-ingress-internal namespace already exists"
kubectl create namespace "infra-cert-manager" 2>/dev/null || print_status "infra-cert-manager namespace already exists"
kubectl create namespace "infra-mail" 2>/dev/null || print_status "infra-mail namespace already exists"

# Tenant namespaces (tn-<tenant>-*)
print_status "Creating tenant namespaces..."
kubectl create namespace "tn-${TENANT}-matrix" 2>/dev/null || print_status "tn-${TENANT}-matrix namespace already exists"
kubectl create namespace "tn-${TENANT}-jitsi" 2>/dev/null || print_status "tn-${TENANT}-jitsi namespace already exists"
kubectl create namespace "tn-${TENANT}-docs" 2>/dev/null || print_status "tn-${TENANT}-docs namespace already exists"
kubectl create namespace "tn-${TENANT}-files" 2>/dev/null || print_status "tn-${TENANT}-files namespace already exists"

echo ""
print_status "Step 4: Show PVCs that need manual migration (if any)"

echo ""
echo "PVCs in old namespaces that contain data:"
echo "=========================================="
kubectl get pvc -n matrix 2>/dev/null || true
kubectl get pvc -n docs 2>/dev/null || true
kubectl get pvc -n files 2>/dev/null || true
kubectl get pvc -n monitoring 2>/dev/null || true
echo ""

print_warning "If the above shows PVCs, you may need to migrate data manually."
print_warning "Options:"
print_warning "  1. Let new deployments create fresh PVCs (data loss for Matrix/Nextcloud)"
print_warning "  2. Manually backup and restore data before running create_env"
print_warning "  3. Use VolumeSnapshots or PVC cloning if your storage class supports it"

echo ""
print_status "Step 5: Summary and next steps"

echo ""
print_success "Migration cleanup complete!"
echo ""
echo "Old resources have been deleted. PVCs are preserved."
echo ""
echo "New namespace structure:"
echo "  Infrastructure: infra-db, infra-auth, infra-monitoring, infra-ingress, etc."
echo "  Tenant: tn-${TENANT}-matrix, tn-${TENANT}-jitsi, tn-${TENANT}-docs, tn-${TENANT}-files"
echo ""
echo "Next steps:"
echo "  1. If you need to preserve data, migrate PVCs now"
echo "  2. Run Terraform to update infrastructure:"
echo "     cd $REPO/infra && terraform apply -var env=$MT_ENV -var tenant_ns_prefix=$TENANT"
echo "  3. Run create_env to deploy applications:"
echo "     ./scripts/create_env --tenant=$TENANT $MT_ENV"
echo ""
echo "Note: The old namespaces can be deleted after verifying the new setup is working:"
echo "      kubectl delete namespace matrix docs files monitoring ingress-nginx ingress-internal cert-manager mail"
