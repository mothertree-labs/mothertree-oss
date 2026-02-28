#!/usr/bin/env bash
set -euo pipefail

echo "--- :jest: Admin Portal tests"

cd apps/admin-portal
# Dependencies are already installed by the npm-check step
npm test
