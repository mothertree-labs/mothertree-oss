#!/usr/bin/env bash
set -euo pipefail

# Renew the tenant lease TTL at the end of each pipeline.
# Prevents the lease from expiring during long-running shard executions.

: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"

# Ensure a Redis-compatible CLI is available (Alpine containers need redis installed)
if ! command -v valkey-cli &>/dev/null && ! command -v redis-cli &>/dev/null; then
  apk add --no-cache redis > /dev/null 2>&1 || true
fi
VALKEY="${VALKEY_CLI:-$(command -v valkey-cli 2>/dev/null || command -v redis-cli)} -h valkey"

LEASE_TTL=600  # 10 minutes

TENANT=$($VALKEY GET "ci-build-${CI_PIPELINE_NUMBER}" 2>/dev/null || true)

if [[ -z "$TENANT" ]]; then
  echo "WARNING: No tenant lease found for pipeline #${CI_PIPELINE_NUMBER} — nothing to renew"
  exit 0
fi

KEY="ci-tenant-dev-${TENANT}"

# Verify we still own this lease
HOLDER=$($VALKEY GET "$KEY" 2>/dev/null || true)
if [[ "$HOLDER" != "$CI_PIPELINE_NUMBER" ]]; then
  echo "WARNING: Lease for ${TENANT} is held by pipeline #${HOLDER}, not #${CI_PIPELINE_NUMBER}"
  exit 0
fi

$VALKEY EXPIRE "$KEY" "$LEASE_TTL" > /dev/null
$VALKEY EXPIRE "ci-build-${CI_PIPELINE_NUMBER}" "$LEASE_TTL" > /dev/null

echo "Renewed lease: ${TENANT} for pipeline #${CI_PIPELINE_NUMBER} (TTL: ${LEASE_TTL}s)"
