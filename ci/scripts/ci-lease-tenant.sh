#!/usr/bin/env bash
set -euo pipefail

# Acquire a tenant lease from Valkey for parallel CI runs.
#
# Iterates through available pool slots, attempting an atomic SET NX EX
# on each slot's lease key. On success, writes a reverse-lookup key
# (ci-build-<pipeline> → pool ID) so downstream steps can resolve their
# tenant config with a single GET.
#
# Test user creation in Keycloak is handled separately by
# ci/scripts/ci-create-test-users.sh, which runs after deploy-dev-prep so
# the tenant realm is guaranteed to exist (supports cold-start of the
# dev cluster).
#
# Retries every 60s for up to 10 minutes if all slots are occupied.

: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"
: "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required}"

# shellcheck source=ci-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/ci-lib.sh"

# ── Lease configuration ───────────────────────────────────────
# Main merges use a longer TTL because deploy-dev is a no-op (no renewal
# loop running). PR pipelines use a shorter TTL renewed by ci-deploy.sh,
# ci-deploy-app.sh, and e2e shards.
if [[ "${CI_PIPELINE_EVENT:-}" != "pull_request" ]]; then
  LEASE_TTL=7200  # 2 hours — no renewal loop on main merges, ci-release cleans up
else
  LEASE_TTL=1000  # ~17 minutes (renewed by ci-deploy.sh, ci-deploy-app.sh, and e2e shards)
fi

RETRY_INTERVAL=60
MAX_WAIT=3600  # 1 hour — prod deploys on other slots can take 20-30 min

# ── Pool slots (add new slots here when onboarding tenants) ──────
POOLS=(pool1 pool2)

echo "--- CI Tenant Lease (pipeline #${CI_PIPELINE_NUMBER})"
echo "Pool slots: ${POOLS[*]} | TTL: ${LEASE_TTL}s | Event: ${CI_PIPELINE_EVENT:-push}"

# ── Acquire lease ────────────────────────────────────────────────
LEASED_POOL=""
ELAPSED=0

while [[ -z "$LEASED_POOL" ]]; do
  # Shuffle pool order so concurrent pipelines don't all contend on slot 1
  mapfile -t SHUFFLED < <(printf '%s\n' "${POOLS[@]}" | sort -R)
  for pool in "${SHUFFLED[@]}"; do
    KEY="ci-lease-${pool}"
    # SET NX EX: atomic "create if not exists" with TTL
    RESULT=$(vcli SET "$KEY" "$CI_PIPELINE_NUMBER" NX EX "$LEASE_TTL" 2>/dev/null || true)
    if [[ "$RESULT" == "OK" ]]; then
      LEASED_POOL="$pool"
      echo "Leased pool slot: ${pool}"
      break
    else
      HOLDER=$(vcli GET "$KEY" 2>/dev/null || echo "unknown")
      HOLDER_PIPELINE=$(_extract_pipeline_number "$HOLDER")
      if ! _pipeline_is_alive "$HOLDER_PIPELINE"; then
        echo "  ${pool}: held by pipeline #${HOLDER_PIPELINE} which is no longer running — force-acquiring"
        vcli DEL "$KEY" > /dev/null 2>&1 || true
        vcli DEL "ci-build-${HOLDER_PIPELINE}" > /dev/null 2>&1 || true
        RESULT=$(vcli SET "$KEY" "$CI_PIPELINE_NUMBER" NX EX "$LEASE_TTL" 2>/dev/null || true)
        if [[ "$RESULT" == "OK" ]]; then
          LEASED_POOL="$pool"
          echo "  Force-acquired pool slot: ${pool}"
          break
        fi
      fi
      echo "  ${pool}: occupied by pipeline #${HOLDER}"
    fi
  done

  if [[ -z "$LEASED_POOL" ]]; then
    if (( ELAPSED >= MAX_WAIT )); then
      echo "ERROR: Could not lease any pool slot after ${MAX_WAIT}s — all occupied"
      exit 1
    fi
    echo "All slots occupied. Retrying in ${RETRY_INTERVAL}s... (${ELAPSED}/${MAX_WAIT}s)"
    sleep "$RETRY_INTERVAL"
    ELAPSED=$(( ELAPSED + RETRY_INTERVAL ))
  fi
done

# Write reverse-lookup key so downstream steps can find their pool slot
vcli SET "ci-build-${CI_PIPELINE_NUMBER}" "$LEASED_POOL" EX "$LEASE_TTL" > /dev/null

echo "Reverse lookup: ci-build-${CI_PIPELINE_NUMBER} → ${LEASED_POOL}"

# Resolve the leased tenant name for logging.
POOL_KEY=$(echo "$LEASED_POOL" | tr '[:lower:]-' '[:upper:]_')
TENANT_VAR="E2E_${POOL_KEY}_TENANT"
echo "  Pool slot: ${LEASED_POOL}"
echo "  Tenant: ${!TENANT_VAR:-unknown}"
echo "  Pipeline: ${CI_PIPELINE_NUMBER}"
