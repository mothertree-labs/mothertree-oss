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
# Required for the in-cluster Keycloak OIDC pre-check (cold-start gap #15).
# We fetch a live dev kubeconfig from the Linode API so we can probe Keycloak
# via the kubectl API-server proxy — this disambiguates cluster-level failures
# (Keycloak not serving the realm) from edge/TLS/DNS failures on the public URL.
: "${LINODE_CLI_TOKEN:?LINODE_CLI_TOKEN is required for in-cluster Keycloak pre-check}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/ci-lib.sh"
# shellcheck source=../../scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

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
# serve before requesting a token. Pipeline #1293 (cold-start gap #15) failed
# here with no diagnostic detail — the previous probe silently swallowed HTTP
# status, DNS, and TLS errors. Now we split the wait into two layers:
#   (a) In-cluster probe via kubectl proxy — proves Keycloak+realm are up.
#   (b) Public-URL probe with per-attempt diagnostics — surfaces edge/TLS/DNS
#       failures distinctly from cluster-level failures.
# If (a) passes but (b) fails, the cause is TLS/DNS/Cloudflare edge (e.g. a
# wildcard cert that just renewed and hasn't propagated). If both fail,
# Keycloak itself isn't serving the tenant realm.

# ── (a) Fetch a live kubeconfig and gate on the in-cluster probe ──
KCFG_PATH=$(mktemp -t ci-create-test-users-kcfg-XXXXXX)
trap 'rm -f "$KCFG_PATH"' EXIT
if ! ci_fetch_dev_kubeconfig "$KCFG_PATH"; then
  echo "ERROR: Could not fetch dev kubeconfig from Linode API — cannot run in-cluster Keycloak pre-check"
  exit 1
fi
export KUBECONFIG="$KCFG_PATH"
# Mirror the AUTH_HOST convention expected by mt_wait_for_keycloak_oidc; the
# helper itself uses kubectl proxy and ignores AUTH_HOST, but other helpers
# in common.sh may read it.
export AUTH_HOST="auth.${E2E_BASE_DOMAIN}"

# Gate 1: wildcard Certificate ready. The Certificate is named "wildcard-tls"
# (not the secret name) and lives in the tenant matrix namespace. PR #408
# split apex from wildcard; the auth ingress consumes the *secret* derived
# from the wildcard Certificate, so we only wait on wildcard here.
NS_MATRIX="tn-${E2E_TENANT}-matrix"
NS_AUTH="infra-auth"
echo "Waiting for Certificate wildcard-tls in ${NS_MATRIX} to be Ready..."
if ! kubectl wait --for=condition=Ready \
        certificate/wildcard-tls -n "$NS_MATRIX" --timeout=120s 2>&1; then
  echo "WARNING: wildcard-tls Certificate not Ready within 120s"
  kubectl describe certificate/wildcard-tls -n "$NS_MATRIX" 2>&1 | sed 's/^/  /' || true
fi

# Gate 2: reflected wildcard secret exists where Keycloak's ingress reads it.
echo "Checking reflected secret wildcard-tls-${E2E_TENANT} in ${NS_AUTH}..."
if kubectl get secret "wildcard-tls-${E2E_TENANT}" -n "$NS_AUTH" >/dev/null 2>&1; then
  echo "  reflected secret present"
else
  echo "  WARNING: reflected secret wildcard-tls-${E2E_TENANT} NOT found in ${NS_AUTH} (reflector may not have mirrored yet)"
fi

# Gate 3: in-cluster Keycloak OIDC discovery on the tenant realm (not master).
# Uses kubectl API-server proxy — no DNS, no TLS, no ingress.
if ! mt_wait_for_keycloak_oidc "$REALM"; then
  echo "ERROR: In-cluster Keycloak OIDC discovery failed for realm=${REALM}"
  echo "       This means Keycloak or the tenant realm itself is not serving."
  echo "       The public probe is unlikely to succeed; exiting now."
  exit 1
fi

# ── (b) Public-URL probe with per-attempt diagnostics ──────────────
# ~10 min total budget, exponential backoff capped at 30s. Each failed
# attempt emits one line with HTTP code, DNS lookup result, and any TLS
# error so the failure mode is obvious from CI logs.
DISCOVERY_URL="${KEYCLOAK_URL}/realms/${REALM}/.well-known/openid-configuration"
AUTH_HOSTNAME="auth.${E2E_BASE_DOMAIN}"
echo "Waiting for public Keycloak OIDC discovery: ${DISCOVERY_URL}"
PROBE_DEADLINE=$(( $(date +%s) + 600 ))
PROBE_SLEEP=2
PROBE_OK=0
ATTEMPT=0
while (( $(date +%s) < PROBE_DEADLINE )); do
  ATTEMPT=$((ATTEMPT + 1))
  # Curl with verbose to a separate file so we can grep TLS errors without
  # spamming logs on success. -k is NOT used — we want TLS failures to surface.
  CURL_STDERR=$(mktemp -t ci-create-test-users-curl-XXXXXX)
  HTTP_STATUS=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' \
                    "$DISCOVERY_URL" 2>"$CURL_STDERR" || echo "000")
  if [[ "$HTTP_STATUS" == "200" ]]; then
    echo "  attempt ${ATTEMPT}: HTTP 200 — OIDC discovery responsive"
    rm -f "$CURL_STDERR"
    PROBE_OK=1
    break
  fi

  # Failure diagnostics — one line, all key facts.
  # Use getent (always present on glibc systems) instead of dig (not guaranteed
  # to be installed on the CI host).
  DNS_RESULT=$(getent hosts "$AUTH_HOSTNAME" 2>/dev/null | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
  [[ -z "$DNS_RESULT" ]] && DNS_RESULT="NXDOMAIN/timeout"
  TLS_ERR=$(grep -iE 'SSL|TLS|certificate|handshake' "$CURL_STDERR" 2>/dev/null \
              | head -1 | tr -d '\r' | sed 's/^[[:space:]]*//')
  [[ -z "$TLS_ERR" ]] && TLS_ERR="(none)"
  CURL_ERR=$(grep -iE 'curl: \(|Could not resolve|Connection refused|timed out' "$CURL_STDERR" 2>/dev/null \
              | head -1 | tr -d '\r' | sed 's/^[[:space:]]*//')
  [[ -z "$CURL_ERR" ]] && CURL_ERR="(none)"
  echo "  attempt ${ATTEMPT}: HTTP=${HTTP_STATUS} dns=[${DNS_RESULT}] tls=[${TLS_ERR}] curl=[${CURL_ERR}]"
  rm -f "$CURL_STDERR"

  sleep "$PROBE_SLEEP"
  # Exponential backoff capped at 30s.
  PROBE_SLEEP=$(( PROBE_SLEEP * 2 ))
  (( PROBE_SLEEP > 30 )) && PROBE_SLEEP=30
done

if (( PROBE_OK == 0 )); then
  echo "ERROR: Keycloak public OIDC discovery never became responsive at $DISCOVERY_URL"
  echo "       In-cluster probe SUCCEEDED, so Keycloak is serving — the failure is"
  echo "       at the edge layer (DNS, Cloudflare, ingress TLS, or wildcard cert"
  echo "       not yet propagated). See per-attempt diagnostics above."
  exit 1
fi

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
