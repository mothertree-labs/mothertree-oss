#!/usr/bin/env bash
# Valkey-based e2e protection flag — prevents deploy_infra from running
# while e2e tests are active on any pool slot.
#
# Usage:
#   ci/scripts/ci-e2e-lock.sh acquire   # set e2e-active flag for this pipeline's pool
#   ci/scripts/ci-e2e-lock.sh release   # clear flag if we own it
#
# Required env:
#   CI_PIPELINE_NUMBER, CI_VALKEY_PASSWORD
#   CI_PIPELINE_EVENT (optional, included in lock value for debugging)

set -euo pipefail

: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"
: "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required}"

ACTION="${1:?Usage: ci-e2e-lock.sh acquire|release}"

# shellcheck source=ci-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/ci-lib.sh"   # vcli, vcli_del_if

E2E_TTL=2400  # 40 min — e2e suite takes 5-25 min, renewed by ci-renew-lease
LOCK_VALUE="${CI_PIPELINE_NUMBER}#${CI_PIPELINE_EVENT:-unknown}"

# Look up which pool this pipeline leased
POOL=$(vcli GET "ci-build-${CI_PIPELINE_NUMBER}" 2>/dev/null || true)
if [[ -z "$POOL" ]]; then
  echo "WARNING: No pool lease found for pipeline #${CI_PIPELINE_NUMBER} — skipping e2e lock"
  exit 0
fi

E2E_KEY="ci-e2e-active-${POOL}"

do_acquire() {
  # SET (not NX) — all shards in the same pipeline set the same key/value.
  # Last write wins, which is fine since they all write the same pipeline number.
  # This also refreshes the TTL with each shard start.
  vcli SET "$E2E_KEY" "$LOCK_VALUE" EX "$E2E_TTL" > /dev/null
  echo "Acquired e2e lock: ${E2E_KEY} = ${LOCK_VALUE} (TTL: ${E2E_TTL}s)"
}

do_release() {
  # Compare-and-delete rather than GET, compare, DEL: the TTL can lapse between
  # the read and the delete and another pipeline can acquire in that window, in
  # which case an unconditional DEL removes THEIR lock (#647).
  local deleted
  deleted=$(vcli_del_if "$E2E_KEY" "$LOCK_VALUE" 2>/dev/null || echo 0)

  if [[ "$deleted" == "1" ]]; then
    echo "Released e2e lock: ${E2E_KEY}"
    return 0
  fi

  local holder
  holder=$(vcli GET "$E2E_KEY" 2>/dev/null || true)
  if [[ -z "$holder" ]]; then
    echo "e2e lock already released (key absent)"
  else
    echo "e2e lock ${E2E_KEY} held by ${holder}, not us (${LOCK_VALUE}) — not releasing"
  fi
}

case "$ACTION" in
  acquire) do_acquire ;;
  release) do_release ;;
  *) echo "Usage: ci-e2e-lock.sh acquire|release" >&2; exit 1 ;;
esac
