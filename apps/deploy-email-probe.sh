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

mt_require_commands kubectl envsubst

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
    #   - Temporarily switching Stalwart to internal directory
    #   - Creating the bot user with $app$ password and roles: ["user"]
    #   - Reverting Stalwart to oidc directory
    #   - Creating the K8s secret with the bot password
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
