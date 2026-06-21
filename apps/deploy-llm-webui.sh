#!/bin/bash

# Deploy Open WebUI for a tenant (per-tenant LLM chat UI with Keycloak OIDC)
# Uses shared Ollama inference engine in infra-llm namespace.
#
# Usage:
#   ./apps/deploy-llm-webui.sh -e <env> -t <tenant>

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy Open WebUI for a tenant (Keycloak OIDC auth, shared Ollama)."
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
mt_deploy_start "deploy-llm-webui"

mt_require_commands kubectl yq envsubst curl jq

print_status "Deploying Open WebUI for $MT_TENANT ($MT_ENV)"
print_status "  Namespace: $NS_LLM"
print_status "  Host:      $LLM_HOST"
print_status "  Auth:      $AUTH_HOST/realm/$TENANT_KEYCLOAK_REALM"

# Validate required variables and secrets
if [ "${LLM_ENABLED:-false}" != "true" ]; then
    print_warning "LLM is not enabled for $MT_TENANT (features.llm_enabled != true) — skipping"
    exit 0
fi

if [ -z "${LLM_OIDC_CLIENT_SECRET:-}" ] || [ "$LLM_OIDC_CLIENT_SECRET" = "null" ]; then
    print_error "LLM_OIDC_CLIENT_SECRET not set. Add oidc.open_webui_client_secret to tenant secrets."
    exit 1
fi

# Load Keycloak admin password (needed to create/update the OIDC client)
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
    KEYCLOAK_ADMIN_PASSWORD=$(yq '.keycloak.admin_password // ""' "$TENANT_SECRETS" 2>/dev/null)
fi
if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ] || [ "$KEYCLOAK_ADMIN_PASSWORD" = "null" ]; then
    print_error "KEYCLOAK_ADMIN_PASSWORD is required. Set keycloak.admin_password in tenant secrets."
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Ensure namespace exists
# ---------------------------------------------------------------------------
mt_reset_change_tracker
print_status "Ensuring $NS_LLM namespace exists..."
kubectl create namespace "$NS_LLM" --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# 2. Setup Open WebUI OIDC client in Keycloak
# ---------------------------------------------------------------------------
print_status "Setting up Open WebUI OIDC client in Keycloak realm $TENANT_KEYCLOAK_REALM..."

# Access Keycloak through kubectl port-forward (avoids ingress TLS issues).
# Follows the pattern from apps/scripts/ensure-keycloak-smtp.sh.
STALE_PF=$(lsof -ti:8080 2>/dev/null || true)
if [ -n "$STALE_PF" ]; then
    print_status "Killing stale port-forward on port 8080 (PID: $STALE_PF)..."
    kill $STALE_PF 2>/dev/null || true
    sleep 1
fi
print_status "Setting up port-forward to Keycloak..."
kubectl -n "$NS_AUTH" port-forward svc/keycloak-keycloakx-http 8080:80 > /tmp/keycloak-pf.log 2>&1 &
PF_PID=$!
sleep 3

KEYCLOAK_URL="http://localhost:8080"

_cleanup_keycloak_pf() {
    kill $PF_PID 2>/dev/null || true
}
trap _cleanup_keycloak_pf EXIT

# Get admin token
TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    --data-urlencode "username=admin" \
    --data-urlencode "password=$KEYCLOAK_ADMIN_PASSWORD" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" | jq -r '.access_token')

if [ "$TOKEN" = "null" ] || [ -z "$TOKEN" ]; then
    print_error "Failed to get Keycloak admin token"
    exit 1
fi

# Check if client exists
EXISTING_CLIENT=$(curl -s "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=open-webui" \
    -H "Authorization: Bearer $TOKEN")
CLIENT_COUNT=$(echo "$EXISTING_CLIENT" | jq 'length')

CLIENT_CONFIG='{
    "clientId": "open-webui",
    "name": "Open WebUI",
    "enabled": true,
    "protocol": "openid-connect",
    "publicClient": false,
    "secret": "'"$LLM_OIDC_CLIENT_SECRET"'",
    "standardFlowEnabled": true,
    "directAccessGrantsEnabled": false,
    "serviceAccountsEnabled": false,
    "redirectUris": [
        "https://'"$LLM_HOST"'/*"
    ],
    "webOrigins": [
        "https://'"$LLM_HOST"'"
    ],
    "attributes": {
        "pkce.code.challenge.method": "S256"
    }
}'

if [ "$CLIENT_COUNT" -gt 0 ]; then
    print_status "Updating existing open-webui client..."
    CLIENT_UUID=$(echo "$EXISTING_CLIENT" | jq -r '.[0].id')
    curl -s -X PUT "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$CLIENT_UUID" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$CLIENT_CONFIG" > /dev/null
else
    print_status "Creating new open-webui client..."
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$CLIENT_CONFIG" > /dev/null
fi
print_success "Open WebUI OIDC client configured"

# ---------------------------------------------------------------------------
# 3. Create K8s Secret and apply template
# ---------------------------------------------------------------------------
print_status "Creating OIDC client secret in K8s..."
kubectl create secret generic open-webui-oidc \
    -n "$NS_LLM" \
    --from-literal=client-secret="$LLM_OIDC_CLIENT_SECRET" \
    --dry-run=client -o yaml | mt_apply -f -

print_status "Applying Open WebUI manifests..."
export LLM_STORAGE_SIZE="${LLM_STORAGE_SIZE:-500Mi}"
export LLM_MODEL
# Resolve infra config path to read LLM_MODEL
_mt_resolve_infra_config "$MT_ENV" 2>/dev/null || true
if [ -n "$MT_INFRA_CONFIG" ] && [ -f "$MT_INFRA_CONFIG" ]; then
  LLM_MODEL=$(yq '.llm.model // "llama3.2:1b"' "$MT_INFRA_CONFIG")
else
  LLM_MODEL="llama3.2:1b"
fi
envsubst < "${REPO_ROOT}/apps/manifests/llm/open-webui-tenant.yaml.tpl" | mt_apply -f -

# ---------------------------------------------------------------------------
# 4. Wait for rollout
# ---------------------------------------------------------------------------
print_status "Waiting for Open WebUI deployment to roll out..."
kubectl rollout status deployment/open-webui -n "$NS_LLM" --timeout=120s || {
    print_warning "Open WebUI rollout not ready within timeout — dumping pod diagnostics"
    mt_reset_change_tracker
    dump_pod_diagnostics "$NS_LLM" "app=open-webui"
}

# ---------------------------------------------------------------------------
# 5. Verification
# ---------------------------------------------------------------------------
print_status "Verifying Open WebUI pod..."
kubectl get pods -n "$NS_LLM"

# Check that the OIDC discovery endpoint resolves
print_status "Verifying OpenID Connect discovery..."
kubectl run -n "$NS_LLM" --rm -i --restart=Never llm-oidc-check \
    --image=curlimages/curl:latest \
    -- curl -sf "https://$AUTH_HOST/realms/$TENANT_KEYCLOAK_REALM/.well-known/openid-configuration" \
    > /dev/null 2>&1 && \
    print_success "OIDC discovery endpoint reachable" || \
    print_warning "OIDC discovery not reachable from inside cluster (expected if Keycloak ingress uses auth.dev.*)"

# Restart if changes were detected
mt_restart_if_changed deployment/open-webui "$NS_LLM"

print_success "Open WebUI deployed for $MT_TENANT!"
print_success "  URL:  https://${LLM_HOST}"
print_success "  Auth: Keycloak realm $TENANT_KEYCLOAK_REALM via $AUTH_HOST"
