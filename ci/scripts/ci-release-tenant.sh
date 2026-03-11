#!/usr/bin/env bash
set -euo pipefail

# Release the pool lease and clean up pipeline-scoped test users.
# This runs as the final pipeline step (on both success and failure).

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
  fi
else
  echo "WARNING: Missing Keycloak config — skipping user cleanup"
fi

# ── Release Valkey lease ─────────────────────────────────────────
# Only release if we still own it (avoid releasing a re-leased key)
HOLDER=$(vcli GET "$LEASE_KEY" 2>/dev/null || true)
if [[ "$HOLDER" == "$CI_PIPELINE_NUMBER" ]]; then
  vcli DEL "$LEASE_KEY" > /dev/null
  echo "Released lease: ${LEASE_KEY}"
else
  echo "Lease ${LEASE_KEY} held by pipeline #${HOLDER} — not releasing"
fi

vcli DEL "$BUILD_KEY" > /dev/null
echo "Cleaned up: ${BUILD_KEY}"

echo ""
echo "Tenant release complete for pipeline #${CI_PIPELINE_NUMBER}."
