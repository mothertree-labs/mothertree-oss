#!/usr/bin/env bash
set -euo pipefail

# Renew the pool lease TTL at the end of each pipeline.
# Prevents the lease from expiring during long-running shard executions.

: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"
: "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required}"

# Redis-compatible CLI (redis-tools installed on the CI host via Ansible)
_CLI=$(command -v valkey-cli 2>/dev/null || command -v redis-cli)
# shellcheck disable=SC2086
vcli() { $_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning "$@"; }

# Use the existing TTL as the renewal value so we don't accidentally
# downgrade a main-merge lease (7200s) to a PR lease TTL (1000s).
# Falls back to 1000s if TTL can't be read (shouldn't happen).
FALLBACK_TTL=1000

POOL=$(vcli GET "ci-build-${CI_PIPELINE_NUMBER}" 2>/dev/null || true)

if [[ -z "$POOL" ]]; then
  echo "WARNING: No pool lease found for pipeline #${CI_PIPELINE_NUMBER} — nothing to renew"
  exit 0
fi

KEY="ci-lease-${POOL}"

# Verify we still own the lease.
HOLDER=$(vcli GET "$KEY" 2>/dev/null || true)
if [[ -n "$HOLDER" && "$HOLDER" != "$CI_PIPELINE_NUMBER" ]]; then
  echo "WARNING: Lease for ${POOL} is held by pipeline #${HOLDER}, not #${CI_PIPELINE_NUMBER}"
  exit 0
fi

# Read the current TTL to preserve it (main merges use 7200s, PRs use 1000s)
CURRENT_TTL=$(vcli TTL "$KEY" 2>/dev/null || echo "-1")
if (( CURRENT_TTL > 0 )); then
  LEASE_TTL=$CURRENT_TTL
else
  LEASE_TTL=$FALLBACK_TTL
fi

# Renew the actual lease if we own it
if [[ -n "$HOLDER" ]]; then
  vcli EXPIRE "$KEY" "$LEASE_TTL" > /dev/null
  echo "Renewed lease: ${KEY} (TTL: ${LEASE_TTL}s)"
fi

# Renew the reverse-lookup key — ci-release needs it for cleanup
vcli EXPIRE "ci-build-${CI_PIPELINE_NUMBER}" "$LEASE_TTL" > /dev/null
echo "Renewed reverse lookup: ci-build-${CI_PIPELINE_NUMBER} → ${POOL} (TTL: ${LEASE_TTL}s)"

# Renew e2e protection lock if we own it (prevents TTL expiry during long test suites)
E2E_KEY="ci-e2e-active-${POOL}"
E2E_TTL=2400
E2E_HOLDER=$(vcli GET "$E2E_KEY" 2>/dev/null || true)
if [[ -n "$E2E_HOLDER" && "$E2E_HOLDER" == "${CI_PIPELINE_NUMBER}#"* ]]; then
  vcli EXPIRE "$E2E_KEY" "$E2E_TTL" > /dev/null
  echo "Renewed e2e lock: ${E2E_KEY} (TTL: ${E2E_TTL}s)"
fi
