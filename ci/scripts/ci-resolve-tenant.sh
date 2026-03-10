#!/usr/bin/env bash
# Sourceable helper — resolves tenant-specific env vars for the current pipeline.
#
# Usage (at the top of any CI script that needs tenant info):
#   source ci/scripts/ci-resolve-tenant.sh
#
# Reads the leased tenant from Valkey, then uses shell variable indirection
# to map tenant-prefixed env vars (E2E_MOTHERTREE_BASE_DOMAIN) to standard
# names (E2E_BASE_DOMAIN) that existing scripts and tests expect.

: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"

# Ensure a Redis-compatible CLI is available (Alpine containers need redis installed)
if ! command -v valkey-cli &>/dev/null && ! command -v redis-cli &>/dev/null; then
  apk add --no-cache redis > /dev/null 2>&1 || true
fi
VALKEY="${VALKEY_CLI:-$(command -v valkey-cli 2>/dev/null || command -v redis-cli)} -h valkey"

# Look up which tenant this pipeline leased
_CI_TENANT=$($VALKEY GET "ci-build-${CI_PIPELINE_NUMBER}" 2>/dev/null || true)

if [[ -z "$_CI_TENANT" ]]; then
  echo "ERROR: No tenant lease found for pipeline #${CI_PIPELINE_NUMBER}"
  echo "The ci-lease step may have failed or the lease expired."
  exit 1
fi

_TENANT_KEY=$(echo "$_CI_TENANT" | tr '[:lower:]-' '[:upper:]_')

# Resolve a tenant-prefixed env var to its standard name.
# E.g., E2E_MOTHERTREE_BASE_DOMAIN → E2E_BASE_DOMAIN
_resolve_var() {
  local standard="$1"
  local suffix="${standard#E2E_}"
  local tenant_var="E2E_${_TENANT_KEY}_${suffix}"
  local value="${!tenant_var:-}"
  if [[ -n "$value" ]]; then
    export "$standard"="$value"
  fi
}

export E2E_TENANT="$_CI_TENANT"
_resolve_var E2E_BASE_DOMAIN
_resolve_var E2E_KC_REALM
_resolve_var E2E_KC_CLIENT_SECRET
_resolve_var E2E_STALWART_ADMIN_PASSWORD
_resolve_var E2E_STALWART_IMAP_HOST
_resolve_var E2E_STALWART_IMAP_PORT
_resolve_var E2E_ECHO_GROUP_ADDRESS

echo "Resolved tenant: ${_CI_TENANT} (pipeline #${CI_PIPELINE_NUMBER})"

# Clean up internal vars
unset _CI_TENANT _TENANT_KEY
unset -f _resolve_var
