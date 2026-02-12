#!/bin/bash
#
# Create the alertbot Matrix user and obtain an access token for matrix-alertmanager
#
# This script:
# 1. Creates an alertbot user on Matrix using the Synapse admin API
# 2. Logs in to get an access token
# 3. Outputs the token (or saves it to the secrets file if --save is specified)
#
# Required environment variables:
#   MT_ENV - Environment (prod, dev)
#
# Optional environment variables:
#   TENANT                                   - Tenant name (default: example)
#   MATRIX_HOST                              - Matrix hostname (loaded from tenant config if not set)
#   NS_MATRIX                                - Matrix namespace (derived from tenant if not set)
#   TF_VAR_matrix_registration_shared_secret - Shared secret (loaded from tenant secrets if not set)
#
# Usage:
#   MT_ENV=prod ./create-alertbot-user.sh
#   MT_ENV=prod ./create-alertbot-user.sh --save  # Saves token to tenant secrets file
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-/workspace}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Parse arguments
SAVE_TO_SECRETS=false
for arg in "$@"; do
  case "$arg" in
    --save)
      SAVE_TO_SECRETS=true
      ;;
  esac
done

# Check required environment
if [ -z "${MT_ENV:-}" ]; then
  log_error "MT_ENV is not set. Usage: MT_ENV=dev ./create-alertbot-user.sh"
  exit 1
fi

# Standalone mode: derive tenant paths early so they're available for secret loading
TENANT="${TENANT:-example}"
TENANT_CONFIG="$REPO/tenants/$TENANT/$MT_ENV.config.yaml"
TENANT_SECRETS="$REPO/tenants/$TENANT/$MT_ENV.secrets.yaml"

# Check for shared secret
if [ -z "${TF_VAR_matrix_registration_shared_secret:-}" ]; then
  # Try to load from file
  if [ -f "$REPO/matrix-registration-shared-secret.txt" ]; then
    TF_VAR_matrix_registration_shared_secret=$(cat "$REPO/matrix-registration-shared-secret.txt")
  elif [ -f "$TENANT_SECRETS" ]; then
    TF_VAR_matrix_registration_shared_secret=$(yq '.matrix.registration_shared_secret // ""' "$TENANT_SECRETS")
    if [ -z "$TF_VAR_matrix_registration_shared_secret" ] || [ "$TF_VAR_matrix_registration_shared_secret" = "null" ]; then
      log_error "TF_VAR_matrix_registration_shared_secret not found in tenant secrets"
      exit 1
    fi
    log_info "Loaded registration shared secret from tenant secrets"
  else
    log_error "TF_VAR_matrix_registration_shared_secret is not set"
    log_error "Please source your secrets file or ensure tenant secrets exist"
    exit 1
  fi
fi

# Set KUBECONFIG
export KUBECONFIG="${KUBECONFIG:-$REPO/kubeconfig.${MT_ENV}.yaml}"
if [ ! -f "$KUBECONFIG" ]; then
  log_error "Kubeconfig not found: $KUBECONFIG"
  exit 1
fi

# Derive MATRIX_HOST from tenant config when not called from create_env
if [ -z "${MATRIX_HOST:-}" ]; then
    log_info "MATRIX_HOST not set, loading from tenant config ($TENANT)..."
    if [ ! -f "$TENANT_CONFIG" ]; then
      log_error "Tenant config not found: $TENANT_CONFIG"
      exit 1
    fi
    TENANT_ENV_DNS_LABEL=$(yq '.dns.env_dns_label // ""' "$TENANT_CONFIG")
    TENANT_DOMAIN=$(yq '.dns.domain' "$TENANT_CONFIG")
    if [ -n "$TENANT_ENV_DNS_LABEL" ] && [ "$TENANT_ENV_DNS_LABEL" != "null" ]; then
      MATRIX_HOST="matrix.${TENANT_ENV_DNS_LABEL}.${TENANT_DOMAIN}"
    else
      MATRIX_HOST="matrix.${TENANT_DOMAIN}"
    fi
    log_info "Derived MATRIX_HOST=$MATRIX_HOST"
fi
MATRIX_SERVER="$MATRIX_HOST"
MATRIX_URL="https://$MATRIX_HOST"

ALERTBOT_USER="alertbot"
ALERTBOT_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-24)

# Use tenant namespace variables from environment, with default
NS_MATRIX="${NS_MATRIX:-tn-${TENANT}-matrix}"

log_info "Creating alertbot user for $MT_ENV environment"
log_info "Matrix server: $MATRIX_SERVER"
log_info "Namespace: $NS_MATRIX"

# Check if Synapse pod is available
SYNAPSE_POD=$(kubectl -n "$NS_MATRIX" get pods -l app.kubernetes.io/name=matrix-synapse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$SYNAPSE_POD" ]; then
  log_error "Synapse pod not found. Is Matrix deployed?"
  exit 1
fi

log_info "Using Synapse pod: $SYNAPSE_POD"

# Check if user already exists by trying to log in
log_info "Checking if alertbot user already exists..."
EXISTING_TOKEN=$(curl -sk -X POST "$MATRIX_URL/_matrix/client/v3/login" \
  -H "Content-Type: application/json" \
  -d "{\"type\": \"m.login.password\", \"user\": \"$ALERTBOT_USER\", \"password\": \"$ALERTBOT_PASSWORD\"}" 2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || echo "")

if [ -n "$EXISTING_TOKEN" ]; then
  log_warn "User $ALERTBOT_USER already exists and password matches"
  ACCESS_TOKEN="$EXISTING_TOKEN"
else
  # Create the user using register_new_matrix_user
  log_info "Creating user @${ALERTBOT_USER}:${MATRIX_SERVER}..."
  
  CREATE_CMD="kubectl -n "$NS_MATRIX" exec $SYNAPSE_POD -- register_new_matrix_user \
    -c /synapse/config/conf.d/secrets.yaml \
    -u $ALERTBOT_USER \
    -p $ALERTBOT_PASSWORD \
    --no-admin \
    http://localhost:8008"
  
  CREATE_OUTPUT=$(eval $CREATE_CMD 2>&1) || {
    # Check if user already exists
    if echo "$CREATE_OUTPUT" | grep -q "User ID already taken"; then
      log_warn "User already exists. Attempting to get access token..."
      # Try with a different approach - we'll need to reset the password or use existing
      log_error "User exists but password is unknown. Please manually reset the password or delete the user."
      log_error "To delete: kubectl -n "$NS_MATRIX" exec $SYNAPSE_POD -- python -c \"from synapse.storage.databases.main.registration import RegistrationStore; ...\""
      log_error "Or use the Synapse admin API to deactivate and recreate the user."
      exit 1
    else
      log_error "Failed to create user: $CREATE_OUTPUT"
      exit 1
    fi
  }
  
  log_success "User created successfully"
  
  # Get access token by logging in
  log_info "Obtaining access token..."
  LOGIN_RESPONSE=$(curl -sk -X POST "$MATRIX_URL/_matrix/client/v3/login" \
    -H "Content-Type: application/json" \
    -d "{\"type\": \"m.login.password\", \"user\": \"$ALERTBOT_USER\", \"password\": \"$ALERTBOT_PASSWORD\"}")
  
  ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || echo "")
  
  if [ -z "$ACCESS_TOKEN" ]; then
    log_error "Failed to obtain access token"
    log_error "Login response: $LOGIN_RESPONSE"
    exit 1
  fi
fi

log_success "Access token obtained successfully"
echo ""
echo "=============================================="
echo "Alertbot User Created"
echo "=============================================="
echo "User ID: @${ALERTBOT_USER}:${MATRIX_SERVER}"
echo "Password: $ALERTBOT_PASSWORD"
echo "Access Token: $ACCESS_TOKEN"
echo "=============================================="
echo ""

# Export the token for use by deploy-alerting.sh
export MATRIX_ALERTMANAGER_ACCESS_TOKEN="$ACCESS_TOKEN"

# Optionally save to tenant secrets file
if [ "$SAVE_TO_SECRETS" = true ]; then
  if [ -f "$TENANT_SECRETS" ]; then
    log_info "Saving alertbot access token to $TENANT_SECRETS"
    yq -i '.alertbot.access_token = "'"$ACCESS_TOKEN"'"' "$TENANT_SECRETS"
    log_success "Token saved to $TENANT_SECRETS (alertbot.access_token)"
  else
    log_warn "Tenant secrets file not found: $TENANT_SECRETS"
    log_warn "Please manually add to your tenant secrets file:"
    echo "alertbot:"
    echo "  access_token: \"$ACCESS_TOKEN\""
  fi
fi

log_info "Next steps:"
echo "  1. Invite @${ALERTBOT_USER}:${MATRIX_SERVER} to your alerts room"
echo "  2. If --save was not used, add the token to your tenant secrets file:"
echo "     yq -i '.alertbot.access_token = \"$ACCESS_TOKEN\"' $TENANT_SECRETS"
echo "  3. Run deploy-alerting.sh to deploy the matrix-alertmanager"

