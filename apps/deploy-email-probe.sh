#!/bin/bash

# Deploy Email Probe - End-to-end email delivery monitoring
# Sends probe emails through the full mail chain and monitors delivery.
#
# This script:
#   1. Checks if the bot user is already provisioned (K8s secret exists)
#   2. If not, calls create-email-probe-user to provision the bot in Keycloak
#      and Stalwart's internal directory (with directory switch + restart)
#   3. Reads the bot password from the K8s secret
#   4. Deploys K8s resources (ConfigMap, Deployment, Service, ServiceMonitor)
#   5. Deploys the Grafana dashboard ConfigMap
#
# Prerequisites:
#   - Stalwart deployed and running in NS_STALWART namespace
#   - mail_enabled and email_probe_enabled feature flags set to true
#
# Note: Prometheus alert rules are in apps/values/prometheus.yaml and are
# deployed via helmfile (kube-prometheus-stack) during deploy_infra, not here.
#
# Usage:
#   ./apps/deploy-email-probe.sh -e dev -t example

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy Email Probe for a tenant."
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
mt_deploy_start "deploy-email-probe"

mt_require_commands kubectl envsubst curl openssl python3

# Use NS_STALWART as the mail namespace for the email probe
export NS_MAIL="$NS_STALWART"

print_status "Deploying Email Probe for environment: $MT_ENV"
print_status "Tenant: $TENANT"
print_status "Mail namespace: $NS_MAIL"

# Check feature flags
if [ "$MAIL_ENABLED" != "true" ]; then
    print_warning "Mail not enabled for tenant $TENANT (features.mail_enabled is not true)"
    print_warning "Skipping email probe deployment (requires mail)"
    exit 0
fi

if [ "$EMAIL_PROBE_ENABLED" != "true" ]; then
    print_warning "Email probe not enabled for tenant $TENANT (features.email_probe_enabled is not true)"
    print_warning "Skipping email probe deployment"
    exit 0
fi

# Bot email address
export BOT_EMAIL="email-probe@${EMAIL_DOMAIN}"

# Target email (external auto-reply address)
export TARGET_EMAIL="$EMAIL_PROBE_TARGET_EMAIL"
if [ -z "$TARGET_EMAIL" ] || [ "$TARGET_EMAIL" = "null" ] || [[ "$TARGET_EMAIL" == *"PLACEHOLDER"* ]]; then
    print_error "email_probe.target_address not configured in tenant config"
    print_error "Set it to an external address that auto-replies to probe emails"
    exit 1
fi

print_status "Email domain: $EMAIL_DOMAIN"
print_status "Infra domain: $INFRA_DOMAIN"
print_status "Bot email: $BOT_EMAIL"
print_status "Target email: $TARGET_EMAIL"

# =============================================================================
# Bot user provisioning (first-time only)
# =============================================================================
# Check if the bot user has been provisioned (K8s secret exists with password)
if kubectl get secret email-probe-secrets -n "$NS_MAIL" >/dev/null 2>&1; then
    print_status "Bot user already provisioned (email-probe-secrets exists)"
    # Read existing password from K8s secret
    export BOT_PASSWORD=$(kubectl get secret email-probe-secrets -n "$NS_MAIL" -o jsonpath='{.data.BOT_PASSWORD}' | base64 -d)
    if [ -z "$BOT_PASSWORD" ]; then
        print_error "email-probe-secrets exists but BOT_PASSWORD is empty"
        print_error "Delete the secret and re-run, or run: scripts/create-email-probe-user --tenant=$TENANT --env=$MT_ENV"
        exit 1
    fi
    print_success "Bot password loaded from existing K8s secret"
else
    print_status "Bot user not yet provisioned — running create-email-probe-user..."
    if [ ! -x "$REPO_ROOT/scripts/create-email-probe-user" ]; then
        print_error "scripts/create-email-probe-user not found or not executable"
        exit 1
    fi

    # create-email-probe-user handles:
    #   - Creating Keycloak user (for OIDC directory resolution)
    #   - Creating the Stalwart account + a `probe` app password (v1 JMAP;
    #     the secret is server-generated)
    #   - Creating the K8s secret with that app password
    "$REPO_ROOT/scripts/create-email-probe-user" -e "$MT_ENV" -t "$MT_TENANT"

    # Read the password that create-email-probe-user generated
    export BOT_PASSWORD=$(kubectl get secret email-probe-secrets -n "$NS_MAIL" -o jsonpath='{.data.BOT_PASSWORD}' | base64 -d)
    if [ -z "$BOT_PASSWORD" ]; then
        print_error "create-email-probe-user completed but BOT_PASSWORD is empty in K8s secret"
        exit 1
    fi
    print_success "Bot user provisioned and password loaded"
fi

# =============================================================================
# Synthetic OIDC login (Keycloak side)
# =============================================================================
# Besides the app-password round trip, the probe logs in to Stalwart's IMAP
# the way Roundcube does: a Keycloak token (aud=stalwart) over XOAUTH2 on
# :993. Stalwart's health stays green when OIDC discovery or the directory is
# broken, so only a real login catches that. The probe uses its own
# confidential client limited to the password grant, and a password on the
# bot's Keycloak user. Both values live only in email-probe-secrets
# (generated on first deploy, reused after).
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD not set by config.sh}"
: "${TENANT_KEYCLOAK_REALM:?TENANT_KEYCLOAK_REALM not set by config.sh}"
: "${KEYCLOAK_INTERNAL_URL:?KEYCLOAK_INTERNAL_URL not set by config.sh}"
export OIDC_CLIENT_ID="email-probe-login"
OIDC_CLIENT_SECRET=$(kubectl get secret email-probe-secrets -n "$NS_MAIL" -o jsonpath='{.data.OIDC_CLIENT_SECRET}' | base64 -d)
OIDC_USER_PASSWORD=$(kubectl get secret email-probe-secrets -n "$NS_MAIL" -o jsonpath='{.data.OIDC_USER_PASSWORD}' | base64 -d)
if [ -z "$OIDC_CLIENT_SECRET" ]; then
    print_status "Generating the probe's Keycloak client secret..."
    OIDC_CLIENT_SECRET=$(openssl rand -hex 32)
fi
if [ -z "$OIDC_USER_PASSWORD" ]; then
    print_status "Generating the probe user's Keycloak password..."
    OIDC_USER_PASSWORD=$(openssl rand -hex 32)
fi
export OIDC_CLIENT_SECRET OIDC_USER_PASSWORD

if ! kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloakx -n "$NS_AUTH" --timeout=120s >/dev/null; then
    print_error "Keycloak is not ready in $NS_AUTH"
    exit 1
fi
KC_PF_PORT=$((RANDOM % 10000 + 30000))
kubectl -n "$NS_AUTH" port-forward svc/keycloak-keycloakx-http "${KC_PF_PORT}:80" >/dev/null 2>&1 &
KC_PF_PID=$!
_kc_pf_ready=0
for _ in $(seq 1 30); do
    if curl -s -o /dev/null --max-time 2 "http://localhost:${KC_PF_PORT}/realms/master"; then
        _kc_pf_ready=1; break
    fi
    sleep 1
done
if [ "$_kc_pf_ready" != 1 ]; then
    kill "$KC_PF_PID" 2>/dev/null || true
    print_error "Port-forward to Keycloak did not come up"
    exit 1
fi
print_status "Ensuring the probe's Keycloak client and login..."
# Secrets reach the helper through its environment only, never argv.
if ! KC_URL="http://localhost:${KC_PF_PORT}" KC_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD" \
        KC_REALM="$TENANT_KEYCLOAK_REALM" PROBE_CLIENT_ID="$OIDC_CLIENT_ID" \
        PROBE_CLIENT_SECRET="$OIDC_CLIENT_SECRET" PROBE_USERNAME="email-probe" \
        PROBE_PASSWORD="$OIDC_USER_PASSWORD" PROBE_EMAIL="$BOT_EMAIL" \
        python3 -I "$REPO_ROOT/apps/scripts/ensure-email-probe-oidc.py"; then
    kill "$KC_PF_PID" 2>/dev/null || true
    print_error "The probe cannot log in through Keycloak (see above)"
    exit 1
fi
kill "$KC_PF_PID" 2>/dev/null || true
print_success "Probe OIDC login ready (client $OIDC_CLIENT_ID)"
export OIDC_TOKEN_URL="${KEYCLOAK_INTERNAL_URL}/realms/${TENANT_KEYCLOAK_REALM}/protocol/openid-connect/token"

# Roll the probe when its script or any secret it reads changes (a ConfigMap
# or Secret update alone never restarts it).
EMAIL_PROBE_CHECKSUM=$(cat "$REPO_ROOT/apps/email-probe/email-probe.py" <(printf '%s' "$BOT_PASSWORD$OIDC_CLIENT_SECRET$OIDC_USER_PASSWORD$OIDC_TOKEN_URL") | sha256sum | cut -c1-16)
export EMAIL_PROBE_CHECKSUM

# =============================================================================
# Deploy K8s resources
# =============================================================================

# Create ConfigMap from Python script
print_status "Creating email-probe-script ConfigMap..."
kubectl create configmap email-probe-script \
    --namespace="$NS_MAIL" \
    --from-file=email-probe.py="$REPO_ROOT/apps/email-probe/email-probe.py" \
    --dry-run=client -o yaml | kubectl apply -f -
print_success "ConfigMap created"

# Apply main manifests (Secret, Deployment, Service)
print_status "Applying email-probe manifests..."
envsubst < "$REPO_ROOT/apps/manifests/email-probe/email-probe.yaml.tpl" | kubectl apply -f -
print_success "Email probe Deployment and Service applied"

# Apply ServiceMonitor for Prometheus scraping
print_status "Applying ServiceMonitor..."
envsubst < "$REPO_ROOT/apps/manifests/email-probe/email-probe-servicemonitor.yaml.tpl" | kubectl apply -f -
print_success "ServiceMonitor applied"

# Apply Grafana dashboard ConfigMap (in infra-monitoring namespace)
print_status "Applying Grafana dashboard..."
kubectl apply -f "$REPO_ROOT/apps/manifests/email-probe/email-probe-dashboard-configmap.yaml"
print_success "Grafana dashboard applied"

# Wait for rollout
print_status "Waiting for email-probe Deployment to be ready..."
if kubectl rollout status deployment/email-probe -n "$NS_MAIL" --timeout=120s; then
    print_success "Email probe Deployment is ready"
else
    print_warning "Email probe Deployment may not be fully ready"
    print_status "Check logs with: kubectl logs -n $NS_MAIL -l app=email-probe"
fi

print_success "Email Probe deployed successfully"
echo ""
print_status "Namespace: $NS_MAIL"
print_status "Bot: $BOT_EMAIL -> $TARGET_EMAIL"
print_status "Metrics: kubectl port-forward -n $NS_MAIL svc/email-probe 9090:9090"
print_status "Logs: kubectl logs -n $NS_MAIL -l app=email-probe -f"
print_status "Note: Prometheus alert rules are deployed via deploy_infra (helmfile sync)"
