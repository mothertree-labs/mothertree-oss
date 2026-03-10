#!/usr/bin/env bash
set -euo pipefail

# Acquire a tenant lease from Valkey for parallel CI runs.
#
# Iterates through available tenants, attempting an atomic SET NX EX
# on each tenant's lease key. On success, writes a reverse-lookup key
# (ci-build-<pipeline> → tenant) so downstream steps can resolve their
# tenant with a single GET.
#
# After acquiring the lease, creates pipeline-scoped test users in
# Keycloak so E2E tests have fresh, isolated accounts.
#
# Retries every 60s for up to 10 minutes if all tenants are occupied.

: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"

# Ensure a Redis-compatible CLI is available (Alpine containers need redis installed)
if ! command -v valkey-cli &>/dev/null && ! command -v redis-cli &>/dev/null; then
  apk add --no-cache redis > /dev/null 2>&1 || true
fi
VALKEY="${VALKEY_CLI:-$(command -v valkey-cli 2>/dev/null || command -v redis-cli)} -h valkey"

LEASE_TTL=600  # 10 minutes
RETRY_INTERVAL=60
MAX_WAIT=600

# ── Tenant pool (add new tenants here) ───────────────────────────
TENANTS=(mothertree innba)

echo "--- CI Tenant Lease (pipeline #${CI_PIPELINE_NUMBER})"
echo "Pool: ${TENANTS[*]} | TTL: ${LEASE_TTL}s"

# ── Acquire lease ────────────────────────────────────────────────
LEASED_TENANT=""
ELAPSED=0

while [[ -z "$LEASED_TENANT" ]]; do
  for tenant in "${TENANTS[@]}"; do
    KEY="ci-tenant-dev-${tenant}"
    # SET NX EX: atomic "create if not exists" with TTL
    RESULT=$($VALKEY SET "$KEY" "$CI_PIPELINE_NUMBER" NX EX "$LEASE_TTL" 2>/dev/null || true)
    if [[ "$RESULT" == "OK" ]]; then
      LEASED_TENANT="$tenant"
      echo "Leased tenant: ${tenant}"
      break
    else
      HOLDER=$($VALKEY GET "$KEY" 2>/dev/null || echo "unknown")
      echo "  ${tenant}: occupied by pipeline #${HOLDER}"
    fi
  done

  if [[ -z "$LEASED_TENANT" ]]; then
    if (( ELAPSED >= MAX_WAIT )); then
      echo "ERROR: Could not lease any tenant after ${MAX_WAIT}s — all occupied"
      exit 1
    fi
    echo "All tenants occupied. Retrying in ${RETRY_INTERVAL}s... (${ELAPSED}/${MAX_WAIT}s)"
    sleep "$RETRY_INTERVAL"
    ELAPSED=$(( ELAPSED + RETRY_INTERVAL ))
  fi
done

# Write reverse-lookup key so downstream steps can find their tenant
$VALKEY SET "ci-build-${CI_PIPELINE_NUMBER}" "$LEASED_TENANT" EX "$LEASE_TTL" > /dev/null

echo "Reverse lookup: ci-build-${CI_PIPELINE_NUMBER} → ${LEASED_TENANT}"

# ── Resolve tenant-specific env vars ─────────────────────────────
TENANT_KEY=$(echo "$LEASED_TENANT" | tr '[:lower:]-' '[:upper:]_')

resolve_var() {
  local standard="$1"
  local suffix="${standard#E2E_}"
  local tenant_var="E2E_${TENANT_KEY}_${suffix}"
  local value="${!tenant_var:-}"
  if [[ -n "$value" ]]; then
    export "$standard"="$value"
  fi
}

export E2E_TENANT="$LEASED_TENANT"
resolve_var E2E_BASE_DOMAIN
resolve_var E2E_KC_REALM
resolve_var E2E_KC_CLIENT_SECRET

if [[ -z "${E2E_BASE_DOMAIN:-}" ]]; then
  echo "WARNING: E2E_BASE_DOMAIN not resolved — skipping user creation"
  exit 0
fi

if [[ -z "${E2E_KC_REALM:-}" || -z "${E2E_KC_CLIENT_SECRET:-}" ]]; then
  echo "WARNING: KC realm/secret not resolved — skipping user creation"
  exit 0
fi

# ── Create pipeline-scoped test users in Keycloak ────────────────
KEYCLOAK_URL="https://auth.${E2E_BASE_DOMAIN}"
REALM="${E2E_KC_REALM}"
CLIENT_ID="admin-portal"
PREFIX="e2e-${CI_PIPELINE_NUMBER}"

echo ""
echo "--- Creating test users (prefix: ${PREFIX})"
echo "Keycloak: ${KEYCLOAK_URL} | Realm: ${REALM}"

# Get service account token
TOKEN=$(curl -sf --connect-timeout 10 --max-time 30 -X POST \
  "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${E2E_KC_CLIENT_SECRET}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Failed to get Keycloak service account token"
  exit 1
fi

EMAIL_DOMAIN="${E2E_BASE_DOMAIN}"

# User definitions: name_suffix password is_admin
USERS=(
  "admin:e2e-testpass-admin:true"
  "member:e2e-testpass-member:false"
  "mailrt:e2e-testpass-mailrt:false"
  "mailrcv:e2e-testpass-mailrcv:false"
)

create_user() {
  local suffix="$1" password="$2" is_admin="$3"
  local username="${PREFIX}-${suffix}"
  local email="${username}@${EMAIL_DOMAIN}"

  echo -n "  Creating ${username}... "

  # Create user
  local http_code
  http_code=$(curl -s -w "%{http_code}" -o /tmp/ci-create-user.json -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json
print(json.dumps({
  'username': '${username}',
  'email': '${email}',
  'emailVerified': True,
  'enabled': True,
  'firstName': '${username}',
  'lastName': 'Test',
  'attributes': {
    'userType': ['member'],
    'recoveryEmail': ['${email}'],
    'tenantEmail': ['${email}']
  },
  'requiredActions': [],
  'credentials': [{
    'type': 'password',
    'value': '${password}',
    'temporary': False
  }]
}))
")")

  if [[ "$http_code" == "201" ]]; then
    echo "created"
  elif [[ "$http_code" == "409" ]]; then
    echo "already exists"
  else
    echo "failed (HTTP ${http_code})"
    cat /tmp/ci-create-user.json 2>/dev/null || true
    echo ""
    return 0  # Don't fail the build — tests may still pass
  fi

  # Assign roles
  local user_id
  user_id=$(curl -sf --connect-timeout 10 --max-time 10 \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=${username}&exact=true" \
    -H "Authorization: Bearer $TOKEN" \
    | python3 -c "import json,sys; users=json.load(sys.stdin); print(users[0]['id'] if users else '')" 2>/dev/null || true)

  if [[ -z "$user_id" ]]; then
    echo "    WARNING: Could not find user ID for role assignment"
    return 0
  fi

  # Assign docs-user role
  local role_json
  role_json=$(curl -sf --connect-timeout 10 --max-time 10 \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/roles/docs-user" \
    -H "Authorization: Bearer $TOKEN" 2>/dev/null || true)

  if [[ -n "$role_json" ]]; then
    curl -sf --connect-timeout 10 --max-time 10 -X POST \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}/role-mappings/realm" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "[${role_json}]" > /dev/null 2>&1 || true
  fi

  # Assign tenant-admin role if needed
  if [[ "$is_admin" == "true" ]]; then
    role_json=$(curl -sf --connect-timeout 10 --max-time 10 \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/roles/tenant-admin" \
      -H "Authorization: Bearer $TOKEN" 2>/dev/null || true)

    if [[ -n "$role_json" ]]; then
      curl -sf --connect-timeout 10 --max-time 10 -X POST \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}/role-mappings/realm" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "[${role_json}]" > /dev/null 2>&1 || true
    fi
  fi
}

for user_spec in "${USERS[@]}"; do
  IFS=: read -r suffix password is_admin <<< "$user_spec"
  create_user "$suffix" "$password" "$is_admin"
done

echo ""
echo "Tenant lease acquired and test users created."
echo "  Tenant: ${LEASED_TENANT}"
echo "  Pipeline: ${CI_PIPELINE_NUMBER}"
echo "  Lease TTL: ${LEASE_TTL}s"
