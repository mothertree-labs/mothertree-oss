#!/usr/bin/env bash
# Sourceable helper — resolves pool-specific env vars for the current pipeline.
#
# Usage (at the top of any CI script that needs tenant info):
#   source ci/scripts/ci-resolve-tenant.sh
#
# Reads the leased pool slot from Valkey, then uses shell variable indirection
# to map pool-prefixed env vars (E2E_POOL1_BASE_DOMAIN) to standard names
# (E2E_BASE_DOMAIN) that existing scripts and tests expect.

: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"
: "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required}"

# Redis-compatible CLI (redis-tools installed on the CI host via Ansible)
_CLI=$(command -v valkey-cli 2>/dev/null || command -v redis-cli)
# shellcheck disable=SC2086
_vcli() { $_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning "$@"; }

# Look up which pool slot this pipeline leased
_CI_POOL=$(_vcli GET "ci-build-${CI_PIPELINE_NUMBER}" 2>/dev/null || true)

if [[ -z "$_CI_POOL" ]]; then
  echo "ERROR: No pool lease found for pipeline #${CI_PIPELINE_NUMBER}"
  echo "The ci-lease step may have failed or the lease expired."
  exit 1
fi

_POOL_KEY=$(echo "$_CI_POOL" | tr '[:lower:]-' '[:upper:]_')

# Resolve a pool-prefixed env var to its standard name.
# E.g., E2E_POOL1_BASE_DOMAIN → E2E_BASE_DOMAIN
_resolve_var() {
  local standard="$1"
  local suffix="${standard#E2E_}"
  local pool_var="E2E_${_POOL_KEY}_${suffix}"
  local value="${!pool_var:-}"
  if [[ -n "$value" ]]; then
    export "$standard"="$value"
  fi
}

_resolve_var E2E_TENANT
_resolve_var E2E_BASE_DOMAIN
_resolve_var E2E_KC_REALM
_resolve_var E2E_KC_CLIENT_SECRET
_resolve_var E2E_STALWART_ADMIN_PASSWORD
_resolve_var E2E_STALWART_IMAP_HOST
_resolve_var E2E_STALWART_IMAP_PORT
_resolve_var E2E_ECHO_GROUP_ADDRESS

echo "Resolved pool slot: ${_CI_POOL} → tenant ${E2E_TENANT:-unknown} (pipeline #${CI_PIPELINE_NUMBER})"

# Clean up internal vars
unset _CI_POOL _POOL_KEY _CLI
unset -f _resolve_var _vcli
