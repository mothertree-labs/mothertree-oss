#!/bin/bash

# Ensure Keycloak realm has SMTP server configured for sending emails
# (magic-link, password reset, verification emails, etc.)
#
# Usage: ./apps/scripts/ensure-keycloak-smtp.sh -e dev -t mothertree
#        ./apps/scripts/ensure-keycloak-smtp.sh -e prod -t acme

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"
mt_parse_args "$@"
source "${REPO_ROOT}/scripts/lib/config.sh"
mt_load_tenant_config

# Validate required variables
if [ -z "${TENANT_KEYCLOAK_REALM:-}" ]; then
    print_error "TENANT_KEYCLOAK_REALM is not set. Check tenant config."
    exit 1
fi
if [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]; then
    print_error "KEYCLOAK_ADMIN_PASSWORD is not set."
    print_error "Set it in tenants/<tenant>/${MT_ENV}.secrets.yaml under keycloak.admin_password"
    exit 1
fi

SMTP_DOMAIN="${SMTP_DOMAIN:-${TENANT_DOMAIN}}"
DISPLAY_NAME="${TENANT_DISPLAY_NAME:-${TENANT_KEYCLOAK_REALM}}"
NS_AUTH="${NS_AUTH:-infra-auth}"

# Load SMTP submission creds from the tenant's smtp-credentials Secret.
# The provisioner (scripts/provision-smtp-service-accounts) writes this Secret
# into tn-<tenant>-admin (among other namespaces) with the shared `mailer@`
# principal's app password. Fail-fast if missing — Keycloak SMTP is required
# for magic-link / password-reset flows and silent degradation is dangerous.
source "${REPO_ROOT}/scripts/lib/smtp-credentials.sh"
mt_export_smtp_relay_env "$NS_ADMIN"
: "${SMTP_RELAY_HOST:?smtp-credentials Secret is missing in $NS_ADMIN — run scripts/provision-smtp-service-accounts first}"
: "${SMTP_RELAY_USERNAME:?smtp-credentials.SMTP_RELAY_USERNAME missing}"
: "${SMTP_RELAY_PASSWORD:?smtp-credentials.SMTP_RELAY_PASSWORD missing}"
SMTP_RELAY_PORT="${SMTP_RELAY_PORT:-588}"

print_status "Ensuring SMTP config for realm '$TENANT_KEYCLOAK_REALM' (env=$MT_ENV)"
print_status "  SMTP relay: ${SMTP_RELAY_HOST}:${SMTP_RELAY_PORT} (SASL as ${SMTP_RELAY_USERNAME})"
print_status "  SMTP from:  noreply@${SMTP_DOMAIN}"
print_status "  Display name: ${DISPLAY_NAME}"

# Wait for Keycloak pod to be ready
print_status "Waiting for Keycloak pod..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloakx -n "$NS_AUTH" --timeout=120s || {
    print_error "Keycloak pod not ready"
    exit 1
}

# Kill any stale port-forward on 8080
STALE_PF=$(lsof -ti:8080 2>/dev/null || true)
if [ -n "$STALE_PF" ]; then
    print_status "Killing stale port-forward on port 8080 (PID: $STALE_PF)..."
    kill $STALE_PF 2>/dev/null || true
    sleep 1
fi

# Set up port-forward
print_status "Setting up port-forward to Keycloak..."
kubectl -n "$NS_AUTH" port-forward svc/keycloak-keycloakx-http 8080:80 > /tmp/keycloak-pf.log 2>&1 &
PF_PID=$!
sleep 3

KEYCLOAK_URL="http://localhost:8080"

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

# Get admin access token
print_status "Authenticating with Keycloak admin API..."
ACCESS_TOKEN=$(curl -s -X POST \
  "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  --data-urlencode "username=admin" \
  --data-urlencode "password=$KEYCLOAK_ADMIN_PASSWORD" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=admin-cli" | \
  jq -r '.access_token')

if [ "$ACCESS_TOKEN" = "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    print_error "Failed to get admin access token. Check KEYCLOAK_ADMIN_PASSWORD."
    exit 1
fi
print_success "Authenticated"

# Check current SMTP config
CURRENT_SMTP=$(curl -s \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | \
  jq -r '.smtpServer.host // empty')

if [ -n "$CURRENT_SMTP" ]; then
    print_status "Current SMTP host: $CURRENT_SMTP (will update)"
else
    print_status "No SMTP configured (will set)"
fi

# Build SMTP config — authenticated submission to the tenant's Stalwart:588
# with STARTTLS + SASL PLAIN. From/reply-to uses noreply@<EMAIL_DOMAIN>, which
# the provisioner adds as an alias on the shared `mailer@` principal so
# Stalwart's MAIL FROM alignment check passes.
SMTP_CONFIG='{
  "host": "'"${SMTP_RELAY_HOST}"'",
  "port": "'"${SMTP_RELAY_PORT}"'",
  "from": "noreply@'"${SMTP_DOMAIN}"'",
  "fromDisplayName": "'"${DISPLAY_NAME}"'",
  "replyTo": "noreply@'"${SMTP_DOMAIN}"'",
  "replyToDisplayName": "'"${DISPLAY_NAME}"'",
  "ssl": "false",
  "starttls": "true",
  "auth": "true",
  "user": "'"${SMTP_RELAY_USERNAME}"'",
  "password": "'"${SMTP_RELAY_PASSWORD}"'"
}'

# PUT SMTP config to realm
SMTP_UPDATE=$(curl -s -w "%{http_code}" -o /tmp/smtp_update.json -X PUT \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"smtpServer\": $SMTP_CONFIG}")

if [ "$SMTP_UPDATE" = "204" ]; then
    print_success "SMTP configured: ${SMTP_RELAY_HOST}:${SMTP_RELAY_PORT} (SASL as ${SMTP_RELAY_USERNAME}), from=noreply@${SMTP_DOMAIN}"
else
    print_error "Failed to update SMTP (HTTP $SMTP_UPDATE)"
    if [ -f /tmp/smtp_update.json ]; then
        print_error "Details: $(cat /tmp/smtp_update.json)"
    fi
    exit 1
fi

# Verify
VERIFY_HOST=$(curl -s \
  "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM" \
  -H "Authorization: Bearer $ACCESS_TOKEN" | \
  jq -r '.smtpServer.host // empty')

if [ "$VERIFY_HOST" = "$SMTP_RELAY_HOST" ]; then
    print_success "Verified: SMTP config is active"
else
    print_warning "Verification returned unexpected host: $VERIFY_HOST (expected $SMTP_RELAY_HOST)"
fi
