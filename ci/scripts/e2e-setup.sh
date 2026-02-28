#!/usr/bin/env bash
set -euo pipefail

echo "--- :playwright: E2E Setup (npm ci + Chromium)"

# Woodpecker local backend gives each pipeline its own temp dir (and HOME),
# so the default ~/.cache/ms-playwright is not shared between pipelines.
# Use a fixed path under /tmp so shards can reuse the downloaded browsers.
export PLAYWRIGHT_BROWSERS_PATH=/tmp/playwright-browsers
mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"

cd e2e
npm ci --ignore-scripts
# System deps (libnss3, libatk, etc.) are pre-installed by Ansible.
# Only download the Chromium browser binary here.
npx playwright install chromium
