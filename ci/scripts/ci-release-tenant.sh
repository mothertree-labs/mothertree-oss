#!/usr/bin/env bash
set -euo pipefail

# Release the tenant lease and clean up pipeline-scoped test users.
# This runs as the final pipeline step (on both success and failure).

: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"

# Ensure a Redis-compatible CLI is available (Alpine containers need redis installed)
if ! command -v valkey-cli &>/dev/null && ! command -v redis-cli &>/dev/null; then
  apk add --no-cache redis > /dev/null 2>&1 || true
fi
VALKEY="${VALKEY_CLI:-$(command -v valkey-cli 2>/dev/null || command -v redis-cli)} -h valkey"

echo "--- CI Tenant Release (pipeline #${CI_PIPELINE_NUMBER})"

# ── Look up leased tenant ────────────────────────────────────────
TENANT=$($VALKEY GET "ci-build-${CI_PIPELINE_NUMBER}" 2>/dev/null || true)

if [[ -z "$TENANT" ]]; then
  echo "No tenant lease found for pipeline #${CI_PIPELINE_NUMBER} — nothing to release"
  exit 0
fi

LEASE_KEY="ci-tenant-dev-${TENANT}"
BUILD_KEY="ci-build-${CI_PIPELINE_NUMBER}"

echo "Tenant: ${TENANT}"

# ── Resolve tenant-specific env vars for Keycloak cleanup ────────
TENANT_KEY=$(echo "$TENANT" | tr '[:lower:]-' '[:upper:]_')

resolve_var() {
  local standard="$1"
  local suffix="${standard#E2E_}"
  local tenant_var="E2E_${TENANT_KEY}_${suffix}"
  echo "${!tenant_var:-}"
}

E2E_BASE_DOMAIN=$(resolve_var E2E_BASE_DOMAIN)
E2E_KC_REALM=$(resolve_var E2E_KC_REALM)
E2E_KC_CLIENT_SECRET=$(resolve_var E2E_KC_CLIENT_SECRET)

# ── Clean up Keycloak test users ─────────────────────────────────
PREFIX="e2e-${CI_PIPELINE_NUMBER}-"

if [[ -n "$E2E_BASE_DOMAIN" && -n "$E2E_KC_REALM" && -n "$E2E_KC_CLIENT_SECRET" ]]; then
  KEYCLOAK_URL="https://auth.${E2E_BASE_DOMAIN}"
  REALM="${E2E_KC_REALM}"
  CLIENT_ID="admin-portal"

  echo "Cleaning up users with prefix: ${PREFIX}"
  echo "Keycloak: ${KEYCLOAK_URL} | Realm: ${REALM}"

  # Get service account token
  TOKEN=$(curl -sf --connect-timeout 10 --max-time 30 -X POST \
    "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${E2E_KC_CLIENT_SECRET}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || true)

  if [[ -z "$TOKEN" ]]; then
    echo "WARNING: Failed to get Keycloak token — skipping user cleanup"
  else
    # List and delete pipeline-scoped users
    USERS_TO_DELETE=$(curl -sf --connect-timeout 10 --max-time 30 \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/users?max=10000" \
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
  fi
else
  echo "WARNING: Missing Keycloak config — skipping user cleanup"
fi

# ── Release Valkey lease ─────────────────────────────────────────
# Only release if we still own it (avoid releasing a re-leased key)
HOLDER=$($VALKEY GET "$LEASE_KEY" 2>/dev/null || true)
if [[ "$HOLDER" == "$CI_PIPELINE_NUMBER" ]]; then
  $VALKEY DEL "$LEASE_KEY" > /dev/null
  echo "Released lease: ${LEASE_KEY}"
else
  echo "Lease ${LEASE_KEY} held by pipeline #${HOLDER} — not releasing"
fi

$VALKEY DEL "$BUILD_KEY" > /dev/null
echo "Cleaned up: ${BUILD_KEY}"

echo ""
echo "Tenant release complete for pipeline #${CI_PIPELINE_NUMBER}."
