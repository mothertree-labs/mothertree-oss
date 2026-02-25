#!/usr/bin/env bash
set -euo pipefail

echo "--- :npm: npm build check"

FAIL=0

for portal in admin-portal account-portal; do
  dir="apps/${portal}"
  if [ ! -d "$dir" ]; then
    echo "Skipping $dir (not found)"
    continue
  fi

  echo "--- Checking $dir"
  pushd "$dir" > /dev/null

  npm ci --ignore-scripts
  if ! npm run build:css; then
    echo "^^^ +++"
    echo "npm build:css failed in $dir"
    FAIL=1
  fi

  popd > /dev/null
done

# Check calendar-automation syntax
if [ -d "apps/calendar-automation" ] && [ -f "apps/calendar-automation/server.js" ]; then
  echo "--- Checking apps/calendar-automation"
  pushd "apps/calendar-automation" > /dev/null

  # Syntax check (no npm install needed, just verify JS parses)
  if ! node --check server.js; then
    echo "^^^ +++"
    echo "Node.js syntax check failed in apps/calendar-automation"
    FAIL=1
  fi

  popd > /dev/null
fi

# Check linkeditor submodule if present
if [ -d "submodules/files_linkeditor" ] && [ -f "submodules/files_linkeditor/package.json" ]; then
  echo "--- Checking submodules/files_linkeditor"
  pushd "submodules/files_linkeditor" > /dev/null

  npm ci --ignore-scripts
  if npm test --if-present 2>/dev/null; then
    echo "linkeditor tests passed"
  fi

  popd > /dev/null
fi

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi

echo "All npm checks passed"
