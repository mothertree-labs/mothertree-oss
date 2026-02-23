#!/bin/bash
#
# Create the alertbot Matrix user and obtain an access token for matrix-alertmanager
#
# This script:
# 1. Creates an alertbot user on Matrix using register_new_matrix_user
# 2. Creates a temporary admin user, uses the Synapse Admin API to generate
#    a non-expiring access token for alertbot, then deactivates the temp admin
# 3. Outputs the token (or saves it to the secrets file if --save is specified)
#
# Usage:
#   ./apps/scripts/create-alertbot-user.sh -e prod -t example
#   ./apps/scripts/create-alertbot-user.sh -e prod -t example --save

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant> [--save]"
    echo ""
    echo "Create the alertbot Matrix user and obtain a non-expiring access token."
    echo ""
    echo "Options:"
    echo "  -e <env>       Environment (e.g., dev, prod)"
    echo "  -t <tenant>    Tenant name (e.g., example)"
    echo "  --save         Save the token to the tenant secrets file"
    echo "  -h, --help     Show this help"
}

mt_parse_args "$@"
mt_require_env
mt_require_tenant

source "${REPO_ROOT}/scripts/lib/config.sh"
mt_load_tenant_config

mt_require_commands kubectl openssl yq

SAVE_TO_SECRETS=false
if mt_has_flag "--save"; then
  SAVE_TO_SECRETS=true
fi

TENANT_SECRETS="${MT_SECRETS_FILE:-${REPO_ROOT}/tenants/${MT_TENANT}/${MT_ENV}.secrets.yaml}"
MATRIX_URL="https://$MATRIX_HOST"

ALERTBOT_USER="alertbot"
ALERTBOT_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-24)

print_status "Creating alertbot user for $MT_ENV environment"
print_status "Matrix server: $MATRIX_HOST"
print_status "Namespace: $NS_MATRIX"

# Check if Synapse pod is available
SYNAPSE_POD=$(kubectl -n "$NS_MATRIX" get pods -l app.kubernetes.io/name=matrix-synapse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$SYNAPSE_POD" ]; then
  print_error "Synapse pod not found. Is Matrix deployed?"
  exit 1
fi

print_status "Using Synapse pod: $SYNAPSE_POD"

# Step 1: Ensure alertbot user exists
# Create the user via register_new_matrix_user (will fail harmlessly if it already exists)
print_status "Ensuring alertbot user @${ALERTBOT_USER}:${MATRIX_HOST} exists..."

CREATE_OUTPUT=$(kubectl -n "$NS_MATRIX" exec "$SYNAPSE_POD" -- register_new_matrix_user \
  -c /synapse/config/conf.d/secrets.yaml \
  -u "$ALERTBOT_USER" \
  -p "$ALERTBOT_PASSWORD" \
  --no-admin \
  http://localhost:8008 2>&1) || {
  if echo "$CREATE_OUTPUT" | grep -q "User ID already taken"; then
    print_status "User @${ALERTBOT_USER}:${MATRIX_HOST} already exists (OK)"
  else
    print_error "Failed to create alertbot user: $CREATE_OUTPUT"
    exit 1
  fi
}

# Steps 2-4: Generate token via Synapse Admin API
# Runs a Python script inside the Synapse pod that:
# - Registers (or reuses) a service admin via shared-secret HMAC
# - Uses Admin API to get a puppet token for alertbot
#
# IMPORTANT: The puppet token's validity is tied to the service admin's
# session. Deactivating the service admin invalidates ALL puppet tokens
# it created. The service admin account (mt_svc_alertbot) is kept
# permanently. Since password login is disabled in Synapse, this account
# cannot be used for interactive login.
SVC_ADMIN="mt_svc_alertbot"
SVC_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-24)
ALERTBOT_USER_ID="@${ALERTBOT_USER}:${MATRIX_HOST}"

print_status "Generating token for $ALERTBOT_USER_ID via Admin API..."

ACCESS_TOKEN=$(kubectl -n "$NS_MATRIX" exec -i "$SYNAPSE_POD" -- \
  python3 - "$SVC_ADMIN" "$SVC_ADMIN_PASSWORD" "$ALERTBOT_USER_ID" <<'PYEOF'
import urllib.request, urllib.parse, json, hmac, hashlib, sys, yaml

SYNAPSE_URL = "http://localhost:8008"
SVC_ADMIN = sys.argv[1]
SVC_ADMIN_PASSWORD = sys.argv[2]
ALERTBOT_USER_ID = sys.argv[3]
SERVER_NAME = ALERTBOT_USER_ID.split(":", 1)[1]

# Read shared secret from Synapse config inside the container
with open("/synapse/config/conf.d/secrets.yaml") as f:
    config = yaml.safe_load(f)
shared_secret = config["registration_shared_secret"]

def api_call(method, path, data=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(
        f"{SYNAPSE_URL}{path}", data=body, headers=headers, method=method
    )
    try:
        resp = urllib.request.urlopen(req)
        return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()
        print(f"HTTP {e.code} on {method} {path}: {err_body}", file=sys.stderr)
        raise

# 1. Register service admin via shared-secret HMAC (or reuse if it exists)
nonce = api_call("GET", "/_synapse/admin/v1/register")["nonce"]
mac_msg = f"{nonce}\x00{SVC_ADMIN}\x00{SVC_ADMIN_PASSWORD}\x00admin"
mac = hmac.new(shared_secret.encode(), mac_msg.encode(), hashlib.sha1).hexdigest()
try:
    reg = api_call("POST", "/_synapse/admin/v1/register", {
        "nonce": nonce,
        "username": SVC_ADMIN,
        "password": SVC_ADMIN_PASSWORD,
        "admin": True,
        "mac": mac,
    })
    admin_token = reg["access_token"]
    print(f"Service admin {SVC_ADMIN} registered", file=sys.stderr)
except urllib.error.HTTPError:
    # Already exists — log in via shared-secret registration with a new name,
    # then use that to generate a fresh token for the service admin
    import secrets as _s
    tmp = f"mt_tmp_{_s.token_hex(4)}"
    tmp_pass = _s.token_urlsafe(24)
    nonce2 = api_call("GET", "/_synapse/admin/v1/register")["nonce"]
    mac2_msg = f"{nonce2}\x00{tmp}\x00{tmp_pass}\x00admin"
    mac2 = hmac.new(shared_secret.encode(), mac2_msg.encode(), hashlib.sha1).hexdigest()
    tmp_reg = api_call("POST", "/_synapse/admin/v1/register", {
        "nonce": nonce2, "username": tmp, "password": tmp_pass,
        "admin": True, "mac": mac2,
    })
    tmp_token = tmp_reg["access_token"]
    # Get a fresh token for the existing service admin
    svc_id = urllib.parse.quote(f"@{SVC_ADMIN}:{SERVER_NAME}")
    login_resp = api_call("POST", f"/_synapse/admin/v1/users/{svc_id}/login", {}, tmp_token)
    admin_token = login_resp["access_token"]
    # Deactivate the throwaway tmp admin (its only puppet was for svc_admin,
    # and svc_admin now has its own session token from the login response)
    # Actually, DON'T deactivate — the svc_admin token is puppeted from tmp.
    # Instead, keep tmp alive too. We'll clean up old tmp admins below.
    print(f"Service admin {SVC_ADMIN} already exists, obtained fresh token via {tmp}", file=sys.stderr)

# 2. Generate puppet token for alertbot
encoded_user = urllib.parse.quote(ALERTBOT_USER_ID)
tok = api_call(
    "POST", f"/_synapse/admin/v1/users/{encoded_user}/login", {}, admin_token
)
print(f"Alertbot token generated", file=sys.stderr)

# Output only the token to stdout
print(tok["access_token"])
PYEOF
) || {
  print_error "Failed to generate token (see Python errors above)"
  exit 1
}

if [ -z "$ACCESS_TOKEN" ]; then
  print_error "Failed to obtain token (empty response)"
  exit 1
fi

print_success "Access token obtained successfully"
echo ""
echo "=============================================="
echo "Alertbot User Ready"
echo "=============================================="
echo "User ID: @${ALERTBOT_USER}:${MATRIX_HOST}"
echo "Access Token: $ACCESS_TOKEN"
echo "Token Type: Puppet token (via Synapse Admin API)"
echo "Note: Token is tied to service admin mt_svc_alertbot — do NOT deactivate that account"
echo "=============================================="
echo ""

# Export the token for use by deploy-alerting.sh
export MATRIX_ALERTMANAGER_ACCESS_TOKEN="$ACCESS_TOKEN"

# Optionally save to tenant secrets file
if [ "$SAVE_TO_SECRETS" = true ]; then
  if [ -f "$TENANT_SECRETS" ]; then
    print_status "Saving alertbot access token to $TENANT_SECRETS"
    yq -i '.alertbot.access_token = "'"$ACCESS_TOKEN"'"' "$TENANT_SECRETS"
    print_success "Token saved to $TENANT_SECRETS (alertbot.access_token)"
  else
    print_warning "Tenant secrets file not found: $TENANT_SECRETS"
    print_warning "Please manually add to your tenant secrets file:"
    echo "alertbot:"
    echo "  access_token: \"$ACCESS_TOKEN\""
  fi
fi

print_status "Next steps:"
echo "  1. Invite @${ALERTBOT_USER}:${MATRIX_HOST} to your alerts room and deploy room"
echo "  2. If --save was not used, add the token to your tenant secrets file:"
echo "     yq -i '.alertbot.access_token = \"$ACCESS_TOKEN\"' $TENANT_SECRETS"
echo "  3. Run deploy-alerting.sh -e $MT_ENV -t $MT_TENANT to deploy the matrix-alertmanager"
