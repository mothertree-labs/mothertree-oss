#!/bin/bash

set -euo pipefail

# Test script to create a Matrix user and verify login works
# Usage: ./perf/tools/users/test_matrix_login.sh <env> <username> <password>

if [ $# -lt 3 ]; then
  echo "Usage: $0 <env> <username> <password>" >&2
  echo "Example: $0 dev testuser testpass123" >&2
  exit 1
fi

ENV="$1"
TEST_USERNAME="$2"
TEST_PASSWORD="$3"
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"

# Load secrets to get domain
if [ -f "$REPO/secrets.${ENV}.tfvars.env" ]; then
  # shellcheck disable=SC1091
  source "$REPO/secrets.${ENV}.tfvars.env"
fi

export KUBECONFIG="$REPO/kubeconfig.${ENV}.yaml"

if [[ ! -f "$KUBECONFIG" ]]; then
  echo "[ERROR] Kubeconfig not found: $KUBECONFIG" >&2
  exit 1
fi

# Get Synapse pod first
SYNAPSE_POD=$(kubectl -n tn-${TENANT:-example}-matrix get pods -l app.kubernetes.io/name=matrix-synapse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$SYNAPSE_POD" ]]; then
  echo "[ERROR] Synapse pod not found" >&2
  exit 1
fi

# Get domain from Synapse config (actual server_name)
DOMAIN=$(kubectl -n tn-${TENANT:-example}-matrix exec "$SYNAPSE_POD" -- python3 -c "import yaml; f=open('/synapse/config/homeserver.yaml'); c=yaml.safe_load(f); print(c.get('server_name', 'example.com'))" 2>/dev/null || echo "example.com")
FULL_USER_ID="@${TEST_USERNAME}:${DOMAIN}"

echo "=========================================="
echo "Matrix User Creation & Login Test"
echo "=========================================="
echo "Environment: $ENV"
echo "Username: $TEST_USERNAME"
echo "Full MXID: $FULL_USER_ID"
echo "Domain: $DOMAIN"
echo ""

echo "[INFO] Using Synapse pod: $SYNAPSE_POD"
echo ""

# Step 1: Create user
echo "[STEP 1] Creating Matrix user..."
kubectl -n tn-${TENANT:-example}-matrix exec "$SYNAPSE_POD" -- register_new_matrix_user \
  -c /synapse/config/homeserver.yaml \
  -c /synapse/config/conf.d/secrets.yaml \
  -u "$TEST_USERNAME" \
  -p "$TEST_PASSWORD" \
  --no-admin \
  http://localhost:8008 2>&1 | grep -v "User ID already taken" || true

echo "[INFO] User creation command completed"
echo ""

# Step 2: Get Matrix base URL from env file
MATRIX_BASE_URL=""
if [ -f "$REPO/perf/env/${ENV}.env" ]; then
  # shellcheck disable=SC1090
  source "$REPO/perf/env/${ENV}.env"
  MATRIX_BASE_URL="${MATRIX_BASE_URL:-}"
fi

if [[ -z "$MATRIX_BASE_URL" ]]; then
  echo "[ERROR] MATRIX_BASE_URL not found in perf/env/${ENV}.env" >&2
  exit 1
fi

echo "[STEP 2] Testing login with different username formats..."
echo "[INFO] Matrix base URL: $MATRIX_BASE_URL"
echo ""

# Step 3: Test login with full MXID format
echo "[TEST 1] Login with full MXID: $FULL_USER_ID"
LOGIN_RESPONSE1=$(kubectl -n tn-${TENANT:-example}-matrix exec "$SYNAPSE_POD" -- python3 -c "
import requests
import json
import sys
try:
    res = requests.post('http://localhost:8008/_matrix/client/v3/login', json={
        'type': 'm.login.password',
        'identifier': {'type': 'm.id.user', 'user': '$FULL_USER_ID'},
        'password': '$TEST_PASSWORD'
    }, timeout=10)
    print(f'STATUS:{res.status_code}')
    print(f'BODY:{res.text}')
except Exception as e:
    print(f'ERROR:{str(e)}')
    sys.exit(1)
" 2>&1)

STATUS1=$(echo "$LOGIN_RESPONSE1" | grep "^STATUS:" | cut -d: -f2)
BODY1=$(echo "$LOGIN_RESPONSE1" | grep "^BODY:" | cut -d: -f2-)

if [[ "$STATUS1" == "200" ]]; then
  echo "✅ SUCCESS: Login with full MXID format works!"
  TOKEN1=$(echo "$BODY1" | python3 -c "import sys, json; print(json.load(sys.stdin).get('access_token', ''))" 2>/dev/null || echo "")
  if [[ -n "$TOKEN1" ]]; then
    echo "   Access token obtained: ${TOKEN1:0:20}..."
  fi
else
  echo "❌ FAILED: Status $STATUS1"
  echo "   Response: $BODY1"
fi
echo ""

# Step 4: Test login with just username
echo "[TEST 2] Login with just username: $TEST_USERNAME"
LOGIN_RESPONSE2=$(kubectl -n tn-${TENANT:-example}-matrix exec "$SYNAPSE_POD" -- python3 -c "
import requests
import json
import sys
try:
    res = requests.post('http://localhost:8008/_matrix/client/v3/login', json={
        'type': 'm.login.password',
        'identifier': {'type': 'm.id.user', 'user': '$TEST_USERNAME'},
        'password': '$TEST_PASSWORD'
    }, timeout=10)
    print(f'STATUS:{res.status_code}')
    print(f'BODY:{res.text}')
except Exception as e:
    print(f'ERROR:{str(e)}')
    sys.exit(1)
" 2>&1)

STATUS2=$(echo "$LOGIN_RESPONSE2" | grep "^STATUS:" | cut -d: -f2)
BODY2=$(echo "$LOGIN_RESPONSE2" | grep "^BODY:" | cut -d: -f2-)

if [[ "$STATUS2" == "200" ]]; then
  echo "✅ SUCCESS: Login with just username works!"
  TOKEN2=$(echo "$BODY2" | python3 -c "import sys, json; print(json.load(sys.stdin).get('access_token', ''))" 2>/dev/null || echo "")
  if [[ -n "$TOKEN2" ]]; then
    echo "   Access token obtained: ${TOKEN2:0:20}..."
  fi
else
  echo "❌ FAILED: Status $STATUS2"
  echo "   Response: $BODY2"
fi
echo ""

# Summary
echo "=========================================="
echo "Test Summary"
echo "=========================================="
if [[ "$STATUS1" == "200" ]]; then
  echo "✅ Full MXID format (@username:domain): WORKS"
else
  echo "❌ Full MXID format (@username:domain): FAILED"
fi

if [[ "$STATUS2" == "200" ]]; then
  echo "✅ Username-only format: WORKS"
else
  echo "❌ Username-only format: FAILED"
fi

if [[ "$STATUS1" == "200" || "$STATUS2" == "200" ]]; then
  echo ""
  echo "✅ At least one format works - login should succeed!"
  exit 0
else
  echo ""
  echo "❌ Both formats failed - check user creation and password"
  exit 1
fi

