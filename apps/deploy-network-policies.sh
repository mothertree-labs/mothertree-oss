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
#   7. allow-admin-to-mail-egress   — Admin/Account Portal → Stalwart API (admin namespace only)
#   8. allow-mail-ingress    — Postfix + Roundcube + Admin → Stalwart (mail namespace only)
#
# Targeted ingress restrictions:
#   9. protect-redis         — Restrict Redis to admin/account portal pods (admin namespace only)
#  10. protect-infra-db      — Restrict PostgreSQL to known client namespaces (infra-db)
#
# Note: No default-deny-ingress. Cross-tenant isolation is enforced via egress policies.
# Blanket ingress deny breaks kubelet health probes (which originate from node IPs,
# not pods) and has no clean solution in standard K8s NetworkPolicies.
#
# Usage:
#   ./apps/deploy-network-policies.sh -e dev -t example
#
# Called from create_env after namespaces are created. All tenant namespaces
# (matrix, docs, files, jitsi, mail, webmail, admin) get the base policies.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy NetworkPolicies for tenant isolation."
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

source "${REPO_ROOT}/scripts/lib/notify.sh"
mt_deploy_start "deploy-network-policies"

mt_require_commands kubectl

# Manifest directory
MANIFEST_DIR="$REPO_ROOT/apps/manifests/network-policies"

if [ ! -d "$MANIFEST_DIR" ]; then
    print_error "Network policy manifests not found: $MANIFEST_DIR"
    exit 1
fi

# All tenant namespaces that get the base policies (default-deny + allow-ingress + egress)
TENANT_NAMESPACES=(
    "$NS_MATRIX"
    "$NS_DOCS"
    "$NS_FILES"
    "$NS_JITSI"
    "$NS_STALWART"
    "$NS_WEBMAIL"
    "$NS_ADMIN"
    "$NS_OFFICE"
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
# Apply Jitsi-specific media egress (UDP for ICE/media + TURN TCP)
# =============================================================================
if kubectl get namespace "$NS_JITSI" &>/dev/null; then
    export NAMESPACE="$NS_JITSI"
    print_status "[$NS_JITSI] Applying allow-jitsi-media-egress (UDP for ICE/media + TURN)..."
    envsubst '${NAMESPACE}' < "$MANIFEST_DIR/allow-jitsi-media-egress.yaml.tpl" | kubectl apply -f -
    print_success "[$NS_JITSI] Jitsi media egress policy applied"
else
    print_warning "Jitsi namespace $NS_JITSI does not exist, skipping Jitsi media egress policy"
fi

# =============================================================================
# Apply mail-specific cross-namespace policies
# =============================================================================
if kubectl get namespace "$NS_STALWART" &>/dev/null; then
    export NAMESPACE="$NS_STALWART"
    print_status "[$NS_STALWART] Applying allow-mail-ingress (Postfix + Roundcube → Stalwart)..."
    envsubst '${NAMESPACE} ${TENANT_NAME}' < "$MANIFEST_DIR/allow-mail-ingress.yaml.tpl" | kubectl apply -f -
    print_success "[$NS_STALWART] Mail ingress policy applied"
else
    print_warning "Mail namespace $NS_STALWART does not exist, skipping mail ingress policy"
fi

if kubectl get namespace "$NS_WEBMAIL" &>/dev/null; then
    export NAMESPACE="$NS_WEBMAIL"
    print_status "[$NS_WEBMAIL] Applying allow-webmail-to-mail-egress (Roundcube → Stalwart)..."
    envsubst '${NAMESPACE} ${TENANT_NAME}' < "$MANIFEST_DIR/allow-webmail-to-mail-egress.yaml.tpl" | kubectl apply -f -
    print_success "[$NS_WEBMAIL] Webmail-to-mail egress policy applied"
else
    print_warning "Webmail namespace $NS_WEBMAIL does not exist, skipping webmail-to-mail policy"
fi

# =============================================================================
# Apply admin-to-mail egress (admin portal → Stalwart HTTP API for provisioning/quotas)
# =============================================================================
if kubectl get namespace "$NS_ADMIN" &>/dev/null && kubectl get namespace "$NS_STALWART" &>/dev/null; then
    export NAMESPACE="$NS_ADMIN"
    print_status "[$NS_ADMIN] Applying allow-admin-to-mail-egress (Admin Portal → Stalwart API)..."
    envsubst '${NAMESPACE} ${TENANT_NAME}' < "$MANIFEST_DIR/allow-admin-to-mail-egress.yaml.tpl" | kubectl apply -f -
    print_success "[$NS_ADMIN] Admin-to-mail egress policy applied"
else
    print_warning "Admin or mail namespace does not exist, skipping admin-to-mail egress policy"
fi

# =============================================================================
# Apply admin-to-matrix egress (admin portal → Synapse Admin API for user provisioning)
# =============================================================================
if kubectl get namespace "$NS_ADMIN" &>/dev/null && kubectl get namespace "$NS_MATRIX" &>/dev/null; then
    export NAMESPACE="$NS_ADMIN"
    print_status "[$NS_ADMIN] Applying allow-admin-to-matrix-egress (Admin Portal → Synapse API)..."
    envsubst '${NAMESPACE} ${TENANT_NAME}' < "$MANIFEST_DIR/allow-admin-to-matrix-egress.yaml.tpl" | kubectl apply -f -
    print_success "[$NS_ADMIN] Admin-to-matrix egress policy applied"
else
    print_warning "Admin or matrix namespace does not exist, skipping admin-to-matrix egress policy"
fi

# =============================================================================
# Apply files-to-office egress (Nextcloud → Collabora internal on port 9980)
# =============================================================================
if kubectl get namespace "$NS_FILES" &>/dev/null && kubectl get namespace "$NS_OFFICE" &>/dev/null; then
    export NAMESPACE="$NS_FILES"
    print_status "[$NS_FILES] Applying allow-files-to-office-egress (Nextcloud → Collabora port 9980)..."
    envsubst '${NAMESPACE} ${TENANT_NAME}' < "$MANIFEST_DIR/allow-files-to-office-egress.yaml.tpl" | kubectl apply -f -
    print_success "[$NS_FILES] Files-to-office egress policy applied"
else
    print_warning "Files or office namespace does not exist, skipping files-to-office egress policy"
fi

# =============================================================================
# Apply Redis protection to admin namespace
# =============================================================================
if kubectl get namespace "$NS_ADMIN" &>/dev/null; then
    export NAMESPACE="$NS_ADMIN"
    print_status "[$NS_ADMIN] Applying protect-redis policy..."
    envsubst '${NAMESPACE}' < "$MANIFEST_DIR/protect-redis.yaml.tpl" | kubectl apply -f -
    print_success "[$NS_ADMIN] Redis protection applied (only admin-portal and account-portal can connect)"
else
    print_warning "Admin namespace $NS_ADMIN does not exist, skipping Redis protection"
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
print_status "Service-specific egress:"
print_status "  - allow-jitsi-media-egress    (jitsi: UDP for ICE/media + TURN TCP)"
print_status "Cross-namespace policies:"
print_status "  - allow-webmail-to-mail-egress  (webmail → mail: IMAP/SMTP/Sieve)"
print_status "  - allow-admin-to-mail-egress    (admin → mail: Stalwart HTTP API)"
print_status "  - allow-files-to-office-egress  (files → office: Collabora port 9980)"
print_status "  - allow-mail-ingress            (mail: accept from Postfix + Roundcube + Admin)"
print_status "Targeted ingress restrictions:"
print_status "  - protect-redis              (admin namespace: only portal pods)"
print_status "  - allow-db-from-${TENANT}    (infra-db: tenant namespace access)"
print_status "  - allow-db-from-infra        (infra-db: infra service access)"
echo ""
print_status "To verify: kubectl get networkpolicies -A -l app.kubernetes.io/part-of=network-policies"
