#!/usr/bin/env bash
set -euo pipefail

# Clean up ephemeral E2E test users from Keycloak after all shards complete.
#
# Each pipeline's tests create users prefixed with "e2e-<pipeline_number>-".
# This step deletes only users belonging to the current pipeline, so
# overlapping pipelines don't interfere with each other.
#
# Required CI secrets:
#   e2e_base_domain       - dev environment base domain
#   e2e_tenant            - tenant name (= Keycloak realm)
#   e2e_kc_client_id      - admin portal's Keycloak client ID
#   e2e_kc_client_secret  - admin portal's Keycloak client secret

: "${E2E_BASE_DOMAIN:?E2E_BASE_DOMAIN is required}"
: "${E2E_TENANT:?E2E_TENANT is required}"
: "${E2E_KC_CLIENT_ID:?E2E_KC_CLIENT_ID is required}"
: "${E2E_KC_CLIENT_SECRET:?E2E_KC_CLIENT_SECRET is required}"
: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"

KEYCLOAK_URL="https://auth.${E2E_BASE_DOMAIN}"
REALM="${E2E_TENANT}"
PREFIX="e2e-${CI_PIPELINE_NUMBER}-"

echo "--- E2E Cleanup (pipeline #${CI_PIPELINE_NUMBER})"
echo "Keycloak: ${KEYCLOAK_URL} | Realm: ${REALM} | Prefix: ${PREFIX}"

# Get service account token
TOKEN=$(curl -sf -X POST \
  "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${E2E_KC_CLIENT_ID}&client_secret=${E2E_KC_CLIENT_SECRET}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Failed to get Keycloak service account token"
  exit 1
fi

# List all users and find ones matching our pipeline prefix
USERS_TO_DELETE=$(curl -sf \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users?max=10000" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c "
import json, sys, os
users = json.load(sys.stdin)
prefix = os.environ['PREFIX']
for u in users:
    email = u.get('email', '') or ''
    username = u.get('username', '') or ''
    if email.startswith(prefix) or username.startswith(prefix):
        print(u['id'] + '\t' + (email or username))
")

if [[ -z "$USERS_TO_DELETE" ]]; then
  echo "No ephemeral users to clean up."
  exit 0
fi

DELETED=0
FAILED=0

while IFS=$'\t' read -r uid desc; do
  if curl -sf -X DELETE \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${uid}" \
    -H "Authorization: Bearer $TOKEN" > /dev/null 2>&1; then
    echo "  Deleted: $desc"
    ((DELETED++))
  else
    echo "  Failed:  $desc"
    ((FAILED++))
  fi
done <<< "$USERS_TO_DELETE"

echo ""
echo "Cleanup complete: ${DELETED} deleted, ${FAILED} failed."
