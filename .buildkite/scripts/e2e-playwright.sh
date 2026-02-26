#!/usr/bin/env bash
set -euo pipefail

echo "--- :playwright: E2E Browser Tests"

# Requires E2E_BASE_DOMAIN and E2E_TENANT to be set in the Buildkite agent environment.
# These are non-secret config values pointing to the dev environment.
if [[ -z "${E2E_BASE_DOMAIN:-}" || -z "${E2E_TENANT:-}" ]]; then
  echo "Skipping: E2E_BASE_DOMAIN and E2E_TENANT must be set"
  exit 0
fi

cd e2e
npm ci --ignore-scripts
npx playwright install --with-deps chromium
npx playwright test --project=ci
