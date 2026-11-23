#!/bin/bash
#
# Create the alertbot Matrix user and obtain an access token for matrix-alertmanager
#
# Matrix authentication is delegated to the Matrix Authentication Service (MAS,
# #824), so this goes through `mas-cli` in the MAS pod:
#   1. `mas-cli manage register-user` creates @alertbot (no password — it never
#      signs in interactively). An existing user (e.g. migrated from Synapse by
#      syn2mas) is fine.
#   2. `mas-cli manage issue-compatibility-token` mints a non-expiring access
#      token on a dedicated device.
#   3. The token is printed, or saved to the tenant secrets file with --save.
#
# Re-running mints a NEW token (and device); the old one keeps working until
# its session is ended in MAS. Synapse-era alertbot tokens were puppet tokens,
# which syn2mas does not migrate — run this once after the Synapse → MAS
# cutover, then rebuild the deploy vault and redeploy alerting.
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
    echo "Create the alertbot Matrix user (via MAS) and obtain a non-expiring access token."
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

mt_require_commands kubectl yq

SAVE_TO_SECRETS=false
if mt_has_flag "--save"; then
  SAVE_TO_SECRETS=true
fi

TENANT_SECRETS="${MT_SECRETS_FILE:-${MT_TENANTS_DIR}/${MT_TENANT}/${MT_ENV}.secrets.yaml}"
ALERTBOT_USER="alertbot"
ALERTBOT_DEVICE="ALERTMANAGER"

print_status "Creating alertbot user for $MT_ENV environment"
print_status "Matrix server: $MATRIX_HOST"
print_status "Namespace: $NS_MATRIX"

if ! kubectl -n "$NS_MATRIX" rollout status deployment/mas --timeout=120s >/dev/null 2>&1; then
  print_error "MAS (deployment/mas in $NS_MATRIX) is not ready. Is Matrix deployed?"
  exit 1
fi

_mas_cli() {
  kubectl -n "$NS_MATRIX" exec deployment/mas -- mas-cli --config /config/config.yaml "$@" 2>&1
}

# Step 1: ensure the user exists
print_status "Ensuring @${ALERTBOT_USER}:${MATRIX_HOST} exists in MAS..."
if out=$(_mas_cli manage register-user --yes "$ALERTBOT_USER" --display-name "Alertbot"); then
  print_status "Created @${ALERTBOT_USER}:${MATRIX_HOST}"
elif [[ "$out" == *"User already exists"* ]]; then
  print_status "@${ALERTBOT_USER}:${MATRIX_HOST} already exists"
else
  print_error "Could not create @${ALERTBOT_USER} in MAS:"
  printf '%s\n' "$out" | tail -20 >&2
  exit 1
fi

# Step 2: mint a non-expiring compatibility token. mas-cli logs the token, so
# the output is parsed here and never echoed.
print_status "Issuing a compatibility access token (device $ALERTBOT_DEVICE)..."
if ! out=$(_mas_cli manage issue-compatibility-token "$ALERTBOT_USER" "$ALERTBOT_DEVICE"); then
  print_error "mas-cli issue-compatibility-token failed:"
  printf '%s\n' "$out" | grep -v 'Compatibility token issued' | tail -20 >&2
  exit 1
fi
ACCESS_TOKEN=$(printf '%s\n' "$out" | grep -oE 'Compatibility token issued: mct_[A-Za-z0-9_]+' | tail -1 | sed 's/^Compatibility token issued: //')
unset out
if [ -z "$ACCESS_TOKEN" ]; then
  print_error "mas-cli reported success but no token was found in its output"
  exit 1
fi
print_success "Access token obtained"

# Export the token for use by deploy-alerting.sh
export MATRIX_ALERTMANAGER_ACCESS_TOKEN="$ACCESS_TOKEN"

if [ "$SAVE_TO_SECRETS" = true ]; then
  if [ -f "$TENANT_SECRETS" ]; then
    print_status "Saving alertbot access token to $TENANT_SECRETS"
    ACCESS_TOKEN="$ACCESS_TOKEN" yq -i '.alertbot.access_token = strenv(ACCESS_TOKEN)' "$TENANT_SECRETS"
    print_success "Token saved to $TENANT_SECRETS (alertbot.access_token)"
  else
    print_error "Tenant secrets file not found: $TENANT_SECRETS"
    exit 1
  fi
else
  echo ""
  echo "User ID:      @${ALERTBOT_USER}:${MATRIX_HOST}"
  echo "Access Token: $ACCESS_TOKEN"
  echo ""
fi

print_status "Next steps:"
echo "  1. Make sure @${ALERTBOT_USER}:${MATRIX_HOST} is in your alerts room and deploy room"
echo "  2. Rebuild the deploy vault (scripts/build-deploy-vaults.sh) so CI picks up the new token"
echo "  3. Run deploy-alerting.sh -e $MT_ENV -t $MT_TENANT to redeploy matrix-alertmanager"
