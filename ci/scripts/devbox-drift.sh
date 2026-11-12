#!/usr/bin/env bash
# devbox drift check (scheduled, .woodpecker/devbox-drift.yaml).
#
# scripts/devbox is a path only developers use, so nothing in the PR pipeline
# notices when a change breaks it. This job builds the minimal devbox from the
# plain public checkout (no config submodules, no vault) in a throwaway k3d
# cluster inside devhome-ci, runs the admin-portal login spec against it and
# deletes it again.
#
# It holds the CI pool slot for the whole run: devhome has one slot and 16 GB,
# and a PR's deploy + e2e shards next to a second cluster would starve both.
# The slot comes from ci-lease-tenant.sh, so a dead holder is reclaimed the same
# way as for PR pipelines, and a killed drift run is reclaimed by the next PR.
#
# The devbox CA is not installed anywhere (DEVBOX_TRUST=process): the CI user
# has no root, and a CA in devhome-ci's system store would be trusted by every
# step on the box. The image caches (scripts/devbox cache) stay on devhome-ci
# between runs, so a nightly run pulls little from the internet.
set -euo pipefail

: "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required}"
: "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci-lib.sh
source "$REPO_ROOT/ci/scripts/ci-lib.sh"

DEVBOX="$REPO_ROOT/scripts/devbox"
export DEVBOX_TRUST=process
LEASE_TTL=1800

# ── Lease the pool slot (waits up to an hour behind PR pipelines) ─
"$REPO_ROOT/ci/scripts/ci-lease-tenant.sh"
POOL=$(vcli GET "ci-build-${CI_PIPELINE_NUMBER}")
[[ "$POOL" =~ ^pool[0-9]+$ ]] || { echo "ERROR: no pool lease recorded for pipeline #${CI_PIPELINE_NUMBER}"; exit 1; }
LEASE_KEY="ci-lease-${POOL}"
vcli EXPIRE "$LEASE_KEY" "$LEASE_TTL" >/dev/null
vcli EXPIRE "ci-build-${CI_PIPELINE_NUMBER}" "$LEASE_TTL" >/dev/null

(
  # Interruptible wait with no child process (see ci-deploy.sh): a FIFO with
  # no writer never delivers data or EOF, so `read -t` waits the full time.
  _wait_fifo=$(mktemp -u); mkfifo "$_wait_fifo"; exec 9<>"$_wait_fifo"; rm -f "$_wait_fifo"
  while true; do
    read -t 120 -u 9 _ || true
    vcli_renew_if "$LEASE_KEY" "$CI_PIPELINE_NUMBER" "$LEASE_TTL" >/dev/null 2>&1 || true
    vcli EXPIRE "ci-build-${CI_PIPELINE_NUMBER}" "$LEASE_TTL" >/dev/null 2>&1 || true
  done
) &
RENEW_PID=$!

cleanup() {
  local rc=$?
  set +e
  echo "--- Tearing down the devbox"
  # nuke asks for confirmation on stdin; the image caches are kept.
  echo y | "$DEVBOX" nuke
  kill "$RENEW_PID" 2>/dev/null
  wait "$RENEW_PID" 2>/dev/null
  vcli_del_if "$LEASE_KEY" "$CI_PIPELINE_NUMBER" >/dev/null 2>&1
  vcli DEL "ci-build-${CI_PIPELINE_NUMBER}" >/dev/null 2>&1
  echo "Released ${LEASE_KEY}"
  exit "$rc"
}
trap cleanup EXIT

# A previous run that died before its cleanup may have left a cluster behind.
echo y | "$DEVBOX" nuke >/dev/null 2>&1 || true

echo "--- devbox doctor"
"$DEVBOX" doctor
echo "--- devbox init --profile minimal"
"$DEVBOX" init --profile minimal
echo "--- devbox up"
"$DEVBOX" up
echo "--- devbox cache status"
"$DEVBOX" cache status

echo "--- Login spec against the devbox"
export PLAYWRIGHT_BROWSERS_PATH=/tmp/playwright-browsers
mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
( cd "$REPO_ROOT/e2e" && npm ci --no-audit --no-fund && npx playwright install chromium )
# Run the spec as a developer would: without CI set, global-setup creates the
# e2e-local-* users through scripts/dev-test-users.sh against the devbox, as
# there is no pipeline-scoped user provisioning for it.
env -u CI -u CI_PIPELINE_NUMBER "$DEVBOX" e2e tests/admin-portal/login.spec.ts

echo "devbox drift check passed"
