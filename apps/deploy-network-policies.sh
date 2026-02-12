#!/bin/bash

# Deploy NetworkPolicies for tenant isolation
# This script applies NetworkPolicy manifests to enforce cross-tenant network isolation.
#
# Policies applied:
#
# Egress isolation (per tenant namespace):
#   1. allow-egress-to-infra — Allow egress to shared infra services (DB, Keycloak, Postfix)
#   2. allow-dns-egress      — Allow DNS resolution via kube-system
#   3. allow-internet-egress — Allow HTTPS egress to external services (S3, PyPI, OIDC)
#   4. allow-intra-namespace — Allow pod-to-pod egress within same namespace
#   5. allow-kube-api-egress — Allow egress to K8s API server (for kubectl in jobs)
#
# Cross-namespace (namespace-specific):
#   6. allow-webmail-to-mail-egress — Roundcube → Stalwart (webmail namespace only)
#   7. allow-mail-ingress    — Postfix + Roundcube → Stalwart (mail namespace only)
#
# Targeted ingress restrictions:
#   8. protect-redis         — Restrict Redis to admin/account portal pods (admin namespace only)
#   9. protect-infra-db      — Restrict PostgreSQL to known client namespaces (infra-db)
#
# Note: No default-deny-ingress. Cross-tenant isolation is enforced via egress policies.
# Blanket ingress deny breaks kubelet health probes (which originate from node IPs,
# not pods) and has no clean solution in standard K8s NetworkPolicies.
#
# Usage:
#   MT_ENV=dev TENANT=example ./apps/deploy-network-policies.sh
#
# Called from create_env after namespaces are created. All tenant namespaces
# (matrix, docs, files, jitsi, mail, webmail, admin) get the base policies.
#
# Prerequisites:
#   - TENANT must be set (tenant name, e.g., example)
#   - MT_ENV must be set (environment, e.g., dev or prod)
#   - KUBECONFIG must be set or kubeconfig.<env>.yaml must exist at repo root

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

# Require MT_ENV and TENANT
MT_ENV=${MT_ENV:-}
REPO_ROOT="${REPO_ROOT:-/workspace}"

# Parse nesting level for deploy notifications
NESTING_LEVEL=0
for arg in "$@"; do
  case "$arg" in
    --nesting-level=*) NESTING_LEVEL="${arg#*=}" ;;
  esac
done
_MT_NOTIFY_NESTING_LEVEL=$NESTING_LEVEL

if [ -f "${REPO_ROOT}/scripts/lib/notify.sh" ]; then
    source "${REPO_ROOT}/scripts/lib/notify.sh"
    mt_deploy_start "deploy-network-policies"
fi

if [ -z "${MT_ENV:-}" ]; then
    print_error "MT_ENV is not set. Usage: MT_ENV=dev TENANT=example ./apps/deploy-network-policies.sh"
    exit 1
fi

if [ -z "${TENANT:-}" ]; then
    print_error "TENANT is not set. Usage: MT_ENV=dev TENANT=example ./apps/deploy-network-policies.sh"
    exit 1
fi

export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/kubeconfig.$MT_ENV.yaml}"

# Manifest directory
MANIFEST_DIR="$REPO_ROOT/apps/manifests/network-policies"

if [ ! -d "$MANIFEST_DIR" ]; then
    print_error "Network policy manifests not found: $MANIFEST_DIR"
    exit 1
fi

# Tenant namespace prefix
TENANT_NS_PREFIX="tn-${TENANT}"
export TENANT_NAME="${TENANT}"

# All tenant namespaces that get the base policies (default-deny + allow-ingress + egress)
TENANT_NAMESPACES=(
    "${TENANT_NS_PREFIX}-matrix"
    "${TENANT_NS_PREFIX}-docs"
    "${TENANT_NS_PREFIX}-files"
    "${TENANT_NS_PREFIX}-jitsi"
    "${TENANT_NS_PREFIX}-mail"
    "${TENANT_NS_PREFIX}-webmail"
    "${TENANT_NS_PREFIX}-admin"
)

print_status "Deploying NetworkPolicies for tenant: $TENANT (env: $MT_ENV)"
print_status "Namespaces: ${TENANT_NAMESPACES[*]}"

# =============================================================================
# Apply base policies to all tenant namespaces
# =============================================================================
APPLIED=0
SKIPPED=0

for NS in "${TENANT_NAMESPACES[@]}"; do
    # Check if namespace exists before applying policies
    if ! kubectl get namespace "$NS" &>/dev/null; then
        print_warning "Namespace $NS does not exist, skipping"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    export NAMESPACE="$NS"

    # Clean up legacy policies from earlier deployments
    for legacy_policy in default-deny-ingress allow-from-ingress allow-monitoring-ingress allow-kubelet-probes; do
        kubectl delete networkpolicy "$legacy_policy" -n "$NS" 2>/dev/null && \
            print_status "[$NS] Removed legacy policy: $legacy_policy" || true
    done

    # Note: No default-deny-ingress. Cross-tenant isolation is enforced by egress
    # policies (pods can only send to allowed destinations). Blanket ingress deny
    # breaks kubelet health probes (which come from node IPs, not pods) and has no
    # clean solution in standard Kubernetes NetworkPolicies without hardcoding IPs.
    # Targeted ingress restrictions (protect-redis, protect-infra-db) are applied
    # separately for sensitive services.

    # 1. Allow egress to shared infrastructure
    print_status "[$NS] Applying allow-egress-to-infra..."
    envsubst '${NAMESPACE}' < "$MANIFEST_DIR/allow-infra-egress.yaml.tpl" | kubectl apply -f -

    # 2. Allow DNS egress
    print_status "[$NS] Applying allow-dns-egress..."
    envsubst '${NAMESPACE}' < "$MANIFEST_DIR/allow-dns-egress.yaml.tpl" | kubectl apply -f -

    # 3. Allow HTTPS egress to internet (S3, PyPI, OIDC discovery, etc.)
    print_status "[$NS] Applying allow-internet-egress..."
    envsubst '${NAMESPACE}' < "$MANIFEST_DIR/allow-internet-egress.yaml.tpl" | kubectl apply -f -

    # 4. Allow intra-namespace pod-to-pod communication (redis, sidecars, etc.)
    print_status "[$NS] Applying allow-intra-namespace..."
    envsubst '${NAMESPACE}' < "$MANIFEST_DIR/allow-intra-namespace.yaml.tpl" | kubectl apply -f -

    # 5. Allow egress to Kubernetes API server (for kubectl exec in jobs)
    print_status "[$NS] Applying allow-kube-api-egress..."
    envsubst '${NAMESPACE}' < "$MANIFEST_DIR/allow-kube-api-egress.yaml.tpl" | kubectl apply -f -

    APPLIED=$((APPLIED + 1))
    print_success "[$NS] Base policies applied"
done

# =============================================================================
# Apply mail-specific cross-namespace policies
# =============================================================================
MAIL_NS="${TENANT_NS_PREFIX}-mail"
if kubectl get namespace "$MAIL_NS" &>/dev/null; then
    export NAMESPACE="$MAIL_NS"
    print_status "[$MAIL_NS] Applying allow-mail-ingress (Postfix + Roundcube → Stalwart)..."
    envsubst '${NAMESPACE} ${TENANT_NAME}' < "$MANIFEST_DIR/allow-mail-ingress.yaml.tpl" | kubectl apply -f -
    print_success "[$MAIL_NS] Mail ingress policy applied"
else
    print_warning "Mail namespace $MAIL_NS does not exist, skipping mail ingress policy"
fi

WEBMAIL_NS="${TENANT_NS_PREFIX}-webmail"
if kubectl get namespace "$WEBMAIL_NS" &>/dev/null; then
    export NAMESPACE="$WEBMAIL_NS"
    print_status "[$WEBMAIL_NS] Applying allow-webmail-to-mail-egress (Roundcube → Stalwart)..."
    envsubst '${NAMESPACE} ${TENANT_NAME}' < "$MANIFEST_DIR/allow-webmail-to-mail-egress.yaml.tpl" | kubectl apply -f -
    print_success "[$WEBMAIL_NS] Webmail-to-mail egress policy applied"
else
    print_warning "Webmail namespace $WEBMAIL_NS does not exist, skipping webmail-to-mail policy"
fi

# =============================================================================
# Apply Redis protection to admin namespace
# =============================================================================
ADMIN_NS="${TENANT_NS_PREFIX}-admin"
if kubectl get namespace "$ADMIN_NS" &>/dev/null; then
    export NAMESPACE="$ADMIN_NS"
    print_status "[$ADMIN_NS] Applying protect-redis policy..."
    envsubst '${NAMESPACE}' < "$MANIFEST_DIR/protect-redis.yaml.tpl" | kubectl apply -f -
    print_success "[$ADMIN_NS] Redis protection applied (only admin-portal and account-portal can connect)"
else
    print_warning "Admin namespace $ADMIN_NS does not exist, skipping Redis protection"
fi

# =============================================================================
# Apply PostgreSQL protection to infra-db
# =============================================================================
if kubectl get namespace "infra-db" &>/dev/null; then
    print_status "[infra-db] Applying protect-infra-db policy for tenant $TENANT..."
    envsubst '${TENANT_NAME}' < "$MANIFEST_DIR/protect-infra-db.yaml.tpl" | kubectl apply -f -
    print_success "[infra-db] PostgreSQL protection applied (tenant $TENANT namespaces + infra services allowed)"
else
    print_warning "infra-db namespace does not exist, skipping PostgreSQL protection"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
print_success "NetworkPolicies deployment complete for tenant: $TENANT"
print_status "Namespaces with policies: $APPLIED"
if [ $SKIPPED -gt 0 ]; then
    print_warning "Namespaces skipped (not found): $SKIPPED"
fi
echo ""
print_status "Egress isolation (per tenant namespace):"
print_status "  - allow-egress-to-infra      (allow DB, Keycloak, Postfix)"
print_status "  - allow-dns-egress           (allow DNS resolution)"
print_status "  - allow-internet-egress      (allow HTTPS to external services)"
print_status "  - allow-intra-namespace      (allow pod-to-pod within namespace)"
print_status "  - allow-kube-api-egress      (allow K8s API server for kubectl jobs)"
print_status "Cross-namespace policies:"
print_status "  - allow-webmail-to-mail-egress (webmail → mail: IMAP/SMTP/Sieve)"
print_status "  - allow-mail-ingress         (mail: accept from Postfix + Roundcube)"
print_status "Targeted ingress restrictions:"
print_status "  - protect-redis              (admin namespace: only portal pods)"
print_status "  - allow-db-from-${TENANT}    (infra-db: tenant namespace access)"
print_status "  - allow-db-from-infra        (infra-db: infra service access)"
echo ""
print_status "To verify: kubectl get networkpolicies -A -l app.kubernetes.io/part-of=network-policies"
