#!/usr/bin/env bash
# Run the cluster-free shell unit tests. Each test file is a standalone bash
# script that exits non-zero on failure. Discovered by glob, so a new test only
# has to land in one of these locations:
#   scripts/lib/tests/*.test.sh   library helpers (fake kubectl etc.)
#   scripts/tests/*.test.sh       CI library (stubbed curl/sleep)
#   scripts/tests/test-*.sh       DNS / probe / tailscale helpers (stubbed resolvers, kubectl, curl)
set -euo pipefail

echo "--- :bash: Running shell unit tests"
cd "$(dirname "$0")/../.."

FAIL=0
COUNT=0
for t in scripts/lib/tests/*.test.sh scripts/tests/*.test.sh scripts/tests/test-*.sh; do
  [ -e "$t" ] || continue
  COUNT=$((COUNT + 1))
  echo "Running: $t"
  if ! bash "$t"; then
    echo "^^^ +++"
    echo "FAILED: $t"
    FAIL=1
  fi
done

[ "$COUNT" -gt 0 ] || { echo "No shell unit tests found — glob misconfigured?"; exit 1; }
[ "$FAIL" -eq 0 ] || exit 1
echo "All $COUNT shell unit test files passed"
