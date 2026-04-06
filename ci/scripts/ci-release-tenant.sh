#!/usr/bin/env bash
set -euo pipefail

# Release the pool lease and clean up pipeline-scoped test users.
# This runs as the final pipeline step (on both success and failure).
#
# IMPORTANT: The Valkey lease MUST be released even if user cleanup fails.
# We use a trap to guarantee this.

: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"
: "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required}"

# Redis-compatible CLI (redis-tools installed on the CI host via Ansible)
_CLI=$(command -v valkey-cli 2>/dev/null || command -v redis-cli)
# shellcheck disable=SC2086
vcli() { $_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning "$@"; }

echo "--- CI Tenant Release (pipeline #${CI_PIPELINE_NUMBER})"

# ── Look up leased pool slot ─────────────────────────────────────
POOL=$(vcli GET "ci-build-${CI_PIPELINE_NUMBER}" 2>/dev/null || true)

if [[ -z "$POOL" ]]; then
  echo "No pool lease found for pipeline #${CI_PIPELINE_NUMBER} — nothing to release"
  exit 0
fi

LEASE_KEY="ci-lease-${POOL}"
BUILD_KEY="ci-build-${CI_PIPELINE_NUMBER}"

echo "Pool slot: ${POOL}"

# ── Guarantee lease release via trap ───────────────────────────────
# The lease MUST be released even if Keycloak cleanup fails, otherwise
# the pool slot stays locked until TTL expires, blocking other pipelines.
release_lease() {
  echo ""
  echo "--- Releasing e2e lock and Valkey lease"

  # Release e2e protection lock first (unblocks other pipelines' deploy_infra)
  local e2e_key="ci-e2e-active-${POOL}"
  local e2e_holder
  e2e_holder=$(vcli GET "$e2e_key" 2>/dev/null || true)
  if [[ -n "$e2e_holder" && "$e2e_holder" == "${CI_PIPELINE_NUMBER}#"* ]]; then
    vcli DEL "$e2e_key" > /dev/null
    echo "Released e2e lock: ${e2e_key}"
  elif [[ -n "$e2e_holder" ]]; then
    echo "e2e lock ${e2e_key} held by ${e2e_holder} — not releasing"
  fi

  # Release tenant lease
  local holder
  holder=$(vcli GET "$LEASE_KEY" 2>/dev/null || true)
  if [[ "$holder" == "$CI_PIPELINE_NUMBER" ]]; then
    vcli DEL "$LEASE_KEY" > /dev/null
    echo "Released lease: ${LEASE_KEY}"
  else
    echo "Lease ${LEASE_KEY} held by pipeline #${holder:-unknown} — not releasing"
  fi

  vcli DEL "$BUILD_KEY" > /dev/null 2>&1 || true
  echo "Cleaned up: ${BUILD_KEY}"
  echo ""
  echo "Tenant release complete for pipeline #${CI_PIPELINE_NUMBER}."
}
trap release_lease EXIT

# ── Resolve pool-specific env vars for Keycloak cleanup ──────────
POOL_KEY=$(echo "$POOL" | tr '[:lower:]-' '[:upper:]_')

resolve_var() {
  local standard="$1"
  local suffix="${standard#E2E_}"
  local pool_var="E2E_${POOL_KEY}_${suffix}"
  echo "${!pool_var:-}"
}

E2E_BASE_DOMAIN=$(resolve_var E2E_BASE_DOMAIN)
E2E_KC_REALM=$(resolve_var E2E_KC_REALM)
E2E_KC_CLIENT_SECRET=$(resolve_var E2E_KC_CLIENT_SECRET)
E2E_STALWART_ADMIN_PASSWORD=$(resolve_var E2E_STALWART_ADMIN_PASSWORD)

# ── Clean up Keycloak test users ─────────────────────────────────
# This section is best-effort — user cleanup failure must NOT prevent
# lease release. The EXIT trap handles the lease.
PREFIX="e2e-${CI_PIPELINE_NUMBER}-"

if [[ -z "$E2E_BASE_DOMAIN" || -z "$E2E_KC_REALM" || -z "$E2E_KC_CLIENT_SECRET" ]]; then
  echo "WARNING: Missing Keycloak config for user cleanup (BASE_DOMAIN=${E2E_BASE_DOMAIN:-}, REALM=${E2E_KC_REALM:-})"
  echo "Users with prefix '${PREFIX}' will NOT be cleaned up — manual cleanup may be needed."
  exit 0  # EXIT trap will still release lease
fi

KEYCLOAK_URL="https://auth.${E2E_BASE_DOMAIN}"
REALM="${E2E_KC_REALM}"
CLIENT_ID="admin-portal"

echo "Cleaning up users with prefix: ${PREFIX}"
echo "Keycloak: ${KEYCLOAK_URL} | Realm: ${REALM}"

# Get service account token — capture response to diagnose failures.
TOKEN_RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -w "\n%{http_code}" -X POST \
  "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${E2E_KC_CLIENT_SECRET}" \
  2>&1) || true

HTTP_CODE=$(echo "$TOKEN_RESPONSE" | tail -1)
TOKEN_BODY=$(echo "$TOKEN_RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "WARNING: Keycloak token request failed (HTTP ${HTTP_CODE})"
  echo "Response: ${TOKEN_BODY:-(empty)}"
  echo "Users with prefix '${PREFIX}' will NOT be cleaned up — manual cleanup may be needed."
  exit 0  # EXIT trap will still release lease
fi

TOKEN=$(echo "$TOKEN_BODY" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || true)

if [[ -z "$TOKEN" ]]; then
  echo "WARNING: Failed to extract access_token from Keycloak response"
  echo "Response: ${TOKEN_BODY:-(empty)}"
  echo "Users with prefix '${PREFIX}' will NOT be cleaned up — manual cleanup may be needed."
  exit 0  # EXIT trap will still release lease
fi

# List and delete pipeline-scoped users
USERS_TO_DELETE=$(curl -s --connect-timeout 10 --max-time 30 \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users?search=e2e-${CI_PIPELINE_NUMBER}-&max=100" \
  -H "Authorization: Bearer $TOKEN" \
  | PREFIX="$PREFIX" python3 -c "
import json, sys, os
users = json.load(sys.stdin)
prefix = os.environ['PREFIX']
for u in users:
    email = u.get('email', '') or ''
    username = u.get('username', '') or ''
    if email.startswith(prefix) or username.startswith(prefix):
        print(u['id'] + '\t' + (email or username))
" 2>/dev/null || true)

if [[ -z "$USERS_TO_DELETE" ]]; then
  echo "No ephemeral users to clean up."
else
  DELETED=0
  FAILED=0

  while IFS=$'\t' read -r uid desc; do
    if curl -sf --connect-timeout 10 --max-time 10 -X DELETE \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${uid}" \
      -H "Authorization: Bearer $TOKEN" > /dev/null 2>&1; then
      echo "  Deleted: $desc"
      DELETED=$(( DELETED + 1 ))
    else
      echo "  Failed:  $desc"
      FAILED=$(( FAILED + 1 ))
    fi
  done <<< "$USERS_TO_DELETE"

  echo "Cleanup: ${DELETED} deleted, ${FAILED} failed."
fi

# ── Clean up Stalwart principals ─────────────────────────────────
# Stalwart auto-provisions OIDC principals on first login. These persist
# even after the Keycloak user is deleted, bloating calendar-automation
# scan cycles (each principal = one IMAP connection per poll).
if [[ -n "$E2E_STALWART_ADMIN_PASSWORD" && -n "$E2E_BASE_DOMAIN" ]]; then
  STALWART_URL="https://mail.${E2E_BASE_DOMAIN}"
  STALWART_AUTH=$(echo -n "admin:${E2E_STALWART_ADMIN_PASSWORD}" | base64)

  echo ""
  echo "Cleaning up Stalwart principals with prefix: ${PREFIX}"

  STALWART_USERS=$(curl -sf --connect-timeout 10 --max-time 30 \
    -H "Authorization: Basic $STALWART_AUTH" \
    "${STALWART_URL}/api/principal?types=individual&limit=0" 2>/dev/null \
    | PREFIX="$PREFIX" python3 -c "
import json, sys, os
body = json.load(sys.stdin)
items = body.get('data', {}).get('items', body.get('data', []))
prefix = os.environ['PREFIX']
for u in items:
    name = u.get('name', '')
    if name.startswith(prefix):
        print(name)
" 2>/dev/null || true)

  if [[ -z "$STALWART_USERS" ]]; then
    echo "No Stalwart principals to clean up."
  else
    SW_DELETED=0
    SW_FAILED=0
    while IFS= read -r principal; do
      encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$principal', safe=''))" 2>/dev/null)
      if curl -sf --connect-timeout 10 --max-time 10 -X DELETE \
        -H "Authorization: Basic $STALWART_AUTH" \
        "${STALWART_URL}/api/principal/${encoded}" > /dev/null 2>&1; then
        SW_DELETED=$(( SW_DELETED + 1 ))
      else
        echo "  Failed: $principal"
        SW_FAILED=$(( SW_FAILED + 1 ))
      fi
    done <<< "$STALWART_USERS"
    echo "Stalwart cleanup: ${SW_DELETED} deleted, ${SW_FAILED} failed."
  fi
else
  echo ""
  echo "Skipping Stalwart cleanup (no admin password available)."
fi

# Lease release happens in EXIT trap — no need for explicit release here
