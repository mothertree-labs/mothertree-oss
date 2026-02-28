#!/usr/bin/env bash
set -euo pipefail

echo "--- :playwright: E2E Browser Tests"

# Requires E2E_BASE_DOMAIN and E2E_TENANT to be set in the CI environment.
# These are non-secret config values pointing to the dev environment.
if [[ -z "${E2E_BASE_DOMAIN:-}" || -z "${E2E_TENANT:-}" ]]; then
  echo "Skipping: E2E_BASE_DOMAIN and E2E_TENANT must be set"
  exit 0
fi

# Use the shared browser cache populated by the e2e-setup pipeline.
# If browsers are already present, playwright install is a no-op.
export PLAYWRIGHT_BROWSERS_PATH=/tmp/playwright-browsers

cd e2e
npm ci --ignore-scripts
# System deps (libnss3, libatk, etc.) are pre-installed by Ansible.
# Only download the Chromium browser binary if not already cached.
npx playwright install chromium

SHARD_ARG=""
if [[ -n "${E2E_SHARD:-}" ]]; then
  SHARD_ARG="--shard=${E2E_SHARD}"
  echo "Running shard ${E2E_SHARD}"
fi

npx playwright test --project=ci ${SHARD_ARG}
