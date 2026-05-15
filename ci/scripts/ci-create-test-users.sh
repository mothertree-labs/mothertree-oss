#!/usr/bin/env bash
set -euo pipefail

# Create pipeline-scoped test users in Keycloak.
#
# Runs after deploy-dev-prep so the tenant realm is guaranteed to exist.
# (Splitting this out of ci-lease-tenant.sh removes the cold-start
# chicken-and-egg where ci-lease ran before ensure-dev-cluster but talked to
# Keycloak — see pipeline #1245 for the failure mode.)
#
# Reads the leased pool slot from Valkey via the reverse-lookup key written
# by ci-lease-tenant.sh, then resolves pool-specific env vars before
# provisioning users.

: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"
: "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required}"

# shellcheck source=ci-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/ci-lib.sh"

# ── Resolve leased pool slot from reverse-lookup ─────────────────
LEASED_POOL=$(vcli GET "ci-build-${CI_PIPELINE_NUMBER}" 2>/dev/null || true)
if [[ -z "$LEASED_POOL" ]]; then
  echo "ERROR: No pool slot leased for pipeline #${CI_PIPELINE_NUMBER}"
  echo "ci-build-${CI_PIPELINE_NUMBER} not found in Valkey — was ci-lease-tenant.sh skipped?"
  exit 1
fi

# ── Resolve pool-specific env vars ───────────────────────────────
POOL_KEY=$(echo "$LEASED_POOL" | tr '[:lower:]-' '[:upper:]_')

resolve_var() {
  local standard="$1"
  local suffix="${standard#E2E_}"
  local pool_var="E2E_${POOL_KEY}_${suffix}"
  local value="${!pool_var:-}"
  if [[ -n "$value" ]]; then
    export "$standard"="$value"
  fi
}

resolve_var E2E_TENANT
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

echo "--- Creating test users (prefix: ${PREFIX})"
echo "Keycloak: ${KEYCLOAK_URL} | Realm: ${REALM}"

# Cold-start gate: wait for the tenant realm's OIDC discovery endpoint to
# serve before requesting a token. On a freshly-rolled or cold-started
# cluster, Keycloak takes another 30-90s after pod-Ready to fully boot the
# realm. Pipeline #1163 (Phase 1 PR #376) failed here when an earlier
# version of this code requested a token mid-warm-up and got HTTP 503 from
# nginx. The deploy_infra gate covers cold-start; this re-check covers
# warm-cluster reuse and defense-in-depth.
DISCOVERY_URL="${KEYCLOAK_URL}/realms/${REALM}/.well-known/openid-configuration"
echo "Waiting for Keycloak OIDC discovery: ${DISCOVERY_URL}"
for i in $(seq 1 60); do
  if curl -sf -m 5 "$DISCOVERY_URL" >/dev/null 2>&1; then
    echo "  OIDC discovery responsive after $((i*5))s"
    break
  fi
  if (( i == 60 )); then
    echo "ERROR: Keycloak OIDC discovery never became responsive at $DISCOVERY_URL"
    exit 1
  fi
  sleep 5
done

# Get service account token — capture response first to diagnose failures.
# The previous curl -sf | python3 pipe crashed on empty input (curl suppresses
# error bodies with -f, python3 gets empty stdin, JSONDecodeError kills the
# script before the TOKEN check is reached due to set -eo pipefail).
TOKEN_RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -w "\n%{http_code}" -X POST \
  "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${E2E_KC_CLIENT_SECRET}" \
  2>&1) || true

HTTP_CODE=$(echo "$TOKEN_RESPONSE" | tail -1)
TOKEN_BODY=$(echo "$TOKEN_RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "ERROR: Keycloak token request failed (HTTP ${HTTP_CODE})"
  echo "Response: ${TOKEN_BODY:-(empty)}"
  exit 1
fi

TOKEN=$(echo "$TOKEN_BODY" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || true)

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Failed to extract access_token from Keycloak response"
  echo "Response: ${TOKEN_BODY:-(empty)}"
  exit 1
fi

EMAIL_DOMAIN="${E2E_BASE_DOMAIN}"

# Pipeline-scoped users: created per build, cleaned up on release.
# These are isolated per pipeline to allow parallel builds.
PIPELINE_USERS=(
  "admin:e2e-testpass-admin:true"
  "member:e2e-testpass-member:false"
)

# Fixed (persistent) mail users: NOT pipeline-scoped.
# These must be permanent because:
# - Echo group membership requires known, pre-existing addresses
# - IMAP master-user auth requires pre-existing Stalwart mail principals
# - The pool lease system ensures single-tenancy, so fixed users are safe
FIXED_USERS=(
  "e2e-mailrt:e2e-testpass-mailrt:false"
  "e2e-mailrcv:e2e-testpass-mailrcv:false"
)

create_user() {
  local username="$1" password="$2" is_admin="$3"
  local email="${username}@${EMAIL_DOMAIN}"

  echo -n "  Creating ${username}... "

  # Build JSON payload safely via environment variables
  local http_code
  http_code=$(CI_USER="$username" CI_EMAIL="$email" CI_PASS="$password" python3 -c "
import json, os
print(json.dumps({
  'username': os.environ['CI_USER'],
  'email': os.environ['CI_EMAIL'],
  'emailVerified': True,
  'enabled': True,
  'firstName': os.environ['CI_USER'],
  'lastName': 'Test',
  'attributes': {
    'userType': ['member'],
    'recoveryEmail': [os.environ['CI_EMAIL']],
    'tenantEmail': [os.environ['CI_EMAIL']]
  },
  'requiredActions': [],
  'credentials': [{
    'type': 'password',
    'value': os.environ['CI_PASS'],
    'temporary': False
  }]
}))
" | curl -s -w "%{http_code}" -o /tmp/ci-create-user.json -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @-)

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

# Create pipeline-scoped users (ephemeral, cleaned up on release)
for user_spec in "${PIPELINE_USERS[@]}"; do
  IFS=: read -r suffix password is_admin <<< "$user_spec"
  create_user "${PREFIX}-${suffix}" "$password" "$is_admin"
done

# Ensure fixed mail users exist (persistent, NOT cleaned up on release)
for user_spec in "${FIXED_USERS[@]}"; do
  IFS=: read -r username password is_admin <<< "$user_spec"
  create_user "$username" "$password" "$is_admin"
done

echo ""
echo "Test users created."
echo "  Pool slot: ${LEASED_POOL}"
echo "  Tenant: ${E2E_TENANT:-unknown}"
echo "  Pipeline: ${CI_PIPELINE_NUMBER}"
