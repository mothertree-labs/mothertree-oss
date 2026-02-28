#!/usr/bin/env bash
set -euo pipefail

echo "--- :jest: Admin Portal tests"

cd apps/admin-portal
[ -d node_modules ] || npm ci --ignore-scripts
npm test
