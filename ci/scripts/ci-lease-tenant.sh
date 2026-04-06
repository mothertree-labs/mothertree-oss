#!/usr/bin/env bash
set -euo pipefail

# Acquire a tenant lease from Valkey for parallel CI runs.
#
# Iterates through available pool slots, attempting an atomic SET NX EX
# on each slot's lease key. On success, writes a reverse-lookup key
# (ci-build-<pipeline> → pool ID) so downstream steps can resolve their
# tenant config with a single GET.
#
# After acquiring the lease, creates pipeline-scoped test users in
# Keycloak so E2E tests have fresh, isolated accounts.
#
# Retries every 60s for up to 10 minutes if all slots are occupied.

: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"
: "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required}"

# shellcheck source=ci-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/ci-lib.sh"

# ── Soft lease for main merges ─────────────────────────────────
# On main merges, e2e shards still run against the default pool without
# acquiring a real lease. We set pool1 as the default and still create
# test users so E2E tests can authenticate.
if [[ "${CI_PIPELINE_EVENT:-}" != "pull_request" ]]; then
  LEASED_POOL="pool1"
  echo "--- CI Tenant Lease (pipeline #${CI_PIPELINE_NUMBER})"
  echo "Main merge — using ${LEASED_POOL} as default (no lease acquired)"
  # Use a long TTL (2 hours) so the key survives until ci-release runs.
  # There is no contention for main merges — ci-release deletes the key explicitly.
  vcli SET "ci-build-${CI_PIPELINE_NUMBER}" "$LEASED_POOL" EX 7200 > /dev/null
  echo "Reverse lookup: ci-build-${CI_PIPELINE_NUMBER} → ${LEASED_POOL} (TTL: 7200s)"
else
  LEASE_TTL=1000  # ~17 minutes (renewed by ci-deploy.sh, ci-deploy-app.sh, and e2e shards)
  RETRY_INTERVAL=60
  MAX_WAIT=3600  # 1 hour — prod deploys on other slots can take 20-30 min

  # ── Pool slots (add new slots here when onboarding tenants) ──────
  POOLS=(pool1 pool2)

  echo "--- CI Tenant Lease (pipeline #${CI_PIPELINE_NUMBER})"
  echo "Pool slots: ${POOLS[*]} | TTL: ${LEASE_TTL}s"

  # ── Acquire lease ────────────────────────────────────────────────
  LEASED_POOL=""
  ELAPSED=0

  while [[ -z "$LEASED_POOL" ]]; do
    # Shuffle pool order so concurrent pipelines don't all contend on slot 1
    mapfile -t SHUFFLED < <(printf '%s\n' "${POOLS[@]}" | sort -R)
    for pool in "${SHUFFLED[@]}"; do
      KEY="ci-lease-${pool}"
      # SET NX EX: atomic "create if not exists" with TTL
      RESULT=$(vcli SET "$KEY" "$CI_PIPELINE_NUMBER" NX EX "$LEASE_TTL" 2>/dev/null || true)
      if [[ "$RESULT" == "OK" ]]; then
        LEASED_POOL="$pool"
        echo "Leased pool slot: ${pool}"
        break
      else
        HOLDER=$(vcli GET "$KEY" 2>/dev/null || echo "unknown")
        HOLDER_PIPELINE=$(_extract_pipeline_number "$HOLDER")
        if ! _pipeline_is_alive "$HOLDER_PIPELINE"; then
          echo "  ${pool}: held by pipeline #${HOLDER_PIPELINE} which is no longer running — force-acquiring"
          vcli DEL "$KEY" > /dev/null 2>&1 || true
          vcli DEL "ci-build-${HOLDER_PIPELINE}" > /dev/null 2>&1 || true
          RESULT=$(vcli SET "$KEY" "$CI_PIPELINE_NUMBER" NX EX "$LEASE_TTL" 2>/dev/null || true)
          if [[ "$RESULT" == "OK" ]]; then
            LEASED_POOL="$pool"
            echo "  Force-acquired pool slot: ${pool}"
            break
          fi
        fi
        echo "  ${pool}: occupied by pipeline #${HOLDER}"
      fi
    done

    if [[ -z "$LEASED_POOL" ]]; then
      if (( ELAPSED >= MAX_WAIT )); then
        echo "ERROR: Could not lease any pool slot after ${MAX_WAIT}s — all occupied"
        exit 1
      fi
      echo "All slots occupied. Retrying in ${RETRY_INTERVAL}s... (${ELAPSED}/${MAX_WAIT}s)"
      sleep "$RETRY_INTERVAL"
      ELAPSED=$(( ELAPSED + RETRY_INTERVAL ))
    fi
  done

  # Write reverse-lookup key so downstream steps can find their pool slot
  vcli SET "ci-build-${CI_PIPELINE_NUMBER}" "$LEASED_POOL" EX "$LEASE_TTL" > /dev/null

  echo "Reverse lookup: ci-build-${CI_PIPELINE_NUMBER} → ${LEASED_POOL}"
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

echo ""
echo "--- Creating test users (prefix: ${PREFIX})"
echo "Keycloak: ${KEYCLOAK_URL} | Realm: ${REALM}"

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
