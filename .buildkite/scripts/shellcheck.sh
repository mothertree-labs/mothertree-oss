#!/usr/bin/env bash
set -euo pipefail

echo "--- :bash: Running ShellCheck"

# Find all shell scripts in project directories (excluding submodules and node_modules)
SCRIPTS=$(find scripts apps/scripts apps/deploy-*.sh ci/scripts -name '*.sh' \
  -not -path "*/node_modules/*" \
  -not -path "*/submodules/*" \
  2>/dev/null || true)

# Also check the create_env script (no .sh extension)
if [ -f "scripts/create_env" ]; then
  SCRIPTS="$SCRIPTS scripts/create_env"
fi

if [ -z "$SCRIPTS" ]; then
  echo "No shell scripts found"
  exit 0
fi

FAIL=0
for script in $SCRIPTS; do
  if head -1 "$script" | grep -qE '^#!/.*(bash|sh)' || [[ "$script" == *.sh ]]; then
    echo "Checking: $script"
    if ! shellcheck -S error -x "$script"; then
      FAIL=1
    fi
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "^^^ +++"
  echo "ShellCheck found issues (warning severity)"
  exit 1
fi

echo "All scripts passed ShellCheck"
