#!/usr/bin/env bash
set -euo pipefail

echo "--- :jest: Admin Portal tests"

cd apps/admin-portal
npm ci --ignore-scripts
npm test
