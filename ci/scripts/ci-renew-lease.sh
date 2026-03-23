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

LEASE_TTL=600  # 10 minutes

POOL=$(vcli GET "ci-build-${CI_PIPELINE_NUMBER}" 2>/dev/null || true)

if [[ -z "$POOL" ]]; then
  echo "WARNING: No pool lease found for pipeline #${CI_PIPELINE_NUMBER} — nothing to renew"
  exit 0
fi

KEY="ci-lease-${POOL}"

# Verify we still own the lease (if one exists).
# On main merges, only a reverse-lookup key is set (soft lease) — there is
# no ci-lease-{pool} key, so HOLDER will be empty.  That's fine; we still
# need to renew the reverse-lookup key so ci-release can find it later.
HOLDER=$(vcli GET "$KEY" 2>/dev/null || true)
if [[ -n "$HOLDER" && "$HOLDER" != "$CI_PIPELINE_NUMBER" ]]; then
  echo "WARNING: Lease for ${POOL} is held by pipeline #${HOLDER}, not #${CI_PIPELINE_NUMBER}"
  exit 0
fi

# Renew the actual lease if we own it
if [[ -n "$HOLDER" ]]; then
  vcli EXPIRE "$KEY" "$LEASE_TTL" > /dev/null
  echo "Renewed lease: ${KEY} (TTL: ${LEASE_TTL}s)"
fi

# Always renew the reverse-lookup key — ci-release needs it for cleanup
vcli EXPIRE "ci-build-${CI_PIPELINE_NUMBER}" "$LEASE_TTL" > /dev/null
echo "Renewed reverse lookup: ci-build-${CI_PIPELINE_NUMBER} → ${POOL} (TTL: ${LEASE_TTL}s)"
