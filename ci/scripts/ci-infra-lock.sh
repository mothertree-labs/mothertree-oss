#!/usr/bin/env bash
# Valkey-based locking for deploy_infra — prevents concurrent shared infra deploys
# and ensures deploy_infra doesn't run while e2e tests are active.
#
# Usage:
#   ci/scripts/ci-infra-lock.sh acquire   # blocks until lock acquired
#   ci/scripts/ci-infra-lock.sh release   # releases if we own it
#
# Required env:
#   CI_PIPELINE_NUMBER, CI_VALKEY_PASSWORD
#   CI_PIPELINE_EVENT (optional, included in lock value for debugging)

set -euo pipefail

: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"
: "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required}"

ACTION="${1:?Usage: ci-infra-lock.sh acquire|release}"

# shellcheck source=ci-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/ci-lib.sh"

LOCK_KEY="ci-infra-lock-dev"
LOCK_VALUE="${CI_PIPELINE_NUMBER}#${CI_PIPELINE_EVENT:-unknown}"
LOCK_TTL=600      # 10 min — deploy_infra takes 2-5 min
MAX_WAIT=2700     # 45 min — worst case: wait for e2e suite + deploy
POLL_INTERVAL=15  # seconds between checks

# Known pool slots — used to check for active e2e tests
POOL_SLOTS=(pool1 pool2)

_e2e_tests_running() {
  for pool in "${POOL_SLOTS[@]}"; do
    local holder
    holder=$(vcli GET "ci-e2e-active-${pool}" 2>/dev/null || true)
    if [[ -n "$holder" ]]; then
      # Check if the e2e holder pipeline is still alive
      local holder_pipeline
      holder_pipeline=$(_extract_pipeline_number "$holder")
      if ! _pipeline_is_alive "$holder_pipeline"; then
        echo "  e2e lock on ${pool} held by pipeline #${holder_pipeline} which is no longer running — clearing" >&2
        vcli DEL "ci-e2e-active-${pool}" > /dev/null 2>&1 || true
        continue
      fi
      echo "$holder"
      return 0
    fi
  done
  return 1
}

do_acquire() {
  local elapsed=0

  echo "Acquiring infra lock ($LOCK_KEY) for pipeline #${CI_PIPELINE_NUMBER}..."

  while true; do
    # Check 1: are any e2e tests running?
    local e2e_holder
    e2e_holder=$(_e2e_tests_running) || true
    if [[ -n "$e2e_holder" ]]; then
      echo "  Waiting: e2e tests active ($e2e_holder) [$elapsed/${MAX_WAIT}s]"
      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
      if (( elapsed >= MAX_WAIT )); then
        echo "ERROR: Timed out waiting for e2e tests to finish ($MAX_WAIT s)"
        exit 1
      fi
      continue
    fi

    # Check 2: try to acquire the infra lock
    local result
    result=$(vcli SET "$LOCK_KEY" "$LOCK_VALUE" NX EX "$LOCK_TTL" 2>/dev/null || true)
    if [[ "$result" != "OK" ]]; then
      local holder
      holder=$(vcli GET "$LOCK_KEY" 2>/dev/null || echo "unknown")

      # Check if the lock holder pipeline is still alive
      local holder_pipeline
      holder_pipeline=$(_extract_pipeline_number "$holder")
      if ! _pipeline_is_alive "$holder_pipeline"; then
        echo "  Infra lock held by pipeline #${holder_pipeline} which is no longer running — force-acquiring"
        vcli DEL "$LOCK_KEY" > /dev/null 2>&1 || true
        continue  # retry acquire immediately
      fi

      echo "  Waiting: infra lock held by $holder [$elapsed/${MAX_WAIT}s]"
      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
      if (( elapsed >= MAX_WAIT )); then
        echo "ERROR: Timed out waiting for infra lock ($MAX_WAIT s)"
        exit 1
      fi
      continue
    fi

    # Check 3: recheck e2e after acquiring (close TOCTOU race)
    e2e_holder=$(_e2e_tests_running) || true
    if [[ -n "$e2e_holder" ]]; then
      # e2e started between our check and lock acquire — release and retry
      vcli DEL "$LOCK_KEY" > /dev/null 2>&1 || true
      echo "  Released lock: e2e tests started ($e2e_holder), retrying..."
      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
      continue
    fi

    echo "Acquired infra lock (pipeline #$CI_PIPELINE_NUMBER)"
    break
  done
}

do_release() {
  local holder
  holder=$(vcli GET "$LOCK_KEY" 2>/dev/null || true)

  if [[ -z "$holder" ]]; then
    echo "Infra lock already released (key absent)"
    return 0
  fi

  if [[ "$holder" == "$LOCK_VALUE" ]]; then
    vcli DEL "$LOCK_KEY" > /dev/null
    echo "Released infra lock (pipeline #$CI_PIPELINE_NUMBER)"
  else
    echo "Infra lock held by $holder, not us ($LOCK_VALUE) — not releasing"
  fi
}

case "$ACTION" in
  acquire) do_acquire ;;
  release) do_release ;;
  *) echo "Usage: ci-infra-lock.sh acquire|release" >&2; exit 1 ;;
esac
