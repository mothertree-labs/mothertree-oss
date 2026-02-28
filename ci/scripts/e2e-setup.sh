#!/usr/bin/env bash
set -euo pipefail

echo "--- :playwright: E2E Setup (npm ci + Chromium)"

cd e2e
npm ci --ignore-scripts
# System deps (libnss3, libatk, etc.) are pre-installed by Ansible.
# Only download the Chromium browser binary here.
npx playwright install chromium
