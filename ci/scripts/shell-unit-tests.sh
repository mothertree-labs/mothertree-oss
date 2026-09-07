#!/usr/bin/env bash
# Run the shell unit tests under scripts/lib/tests/*.test.sh (no cluster needed).
# Each test file is a standalone bash script that exits non-zero on failure.
set -euo pipefail

echo "--- :bash: Running shell unit tests"
cd "$(dirname "$0")/../.."

FAIL=0
for t in scripts/lib/tests/*.test.sh; do
  echo "Running: $t"
  if ! bash "$t"; then
    echo "^^^ +++"
    echo "FAILED: $t"
    FAIL=1
  fi
done

[ "$FAIL" -eq 0 ] || exit 1
echo "All shell unit tests passed"
