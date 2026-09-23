#!/usr/bin/env bash
# Lint: dev CI deploys must touch ONLY the leased pool tenant.
#
# Every dev tenant is a pool tenant, so iterating over config/tenants/* in a
# dev deploy path reaches the tenant another pipeline may have leased and be
# deploying or testing at that moment. #446 did exactly that (prep + the LLM
# step, "for all tenants regardless of pool lease"): a PR pipeline ran Docs
# restarts and migrations with its own code inside the main-push pipeline's
# tenant, and pipeline 2337 died racing it on
#   configmaps "health-sidecar-scripts" already exists
#
# Allowed: the prod ALL_TENANTS loop in ci-deploy.sh. Nothing else in
# ci-deploy.sh or ci-deploy-app.sh may glob config/tenants/*/<env>.config.yaml.
# Invoked by ci/scripts/shell-unit-tests.sh.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || { echo "FAIL: cannot cd to repo root"; exit 1; }

fail=0
glob='config/tenants"/\*/"\$\{MT_ENV\}\.config\.yaml'

# ci-deploy.sh: exactly one tenant loop, and it must sit inside the
# `if [[ "$ALL_TENANTS" == "true" ]]` branch (closed by the next top-level else).
deploy=ci/scripts/ci-deploy.sh
[ -f "$deploy" ] || { echo "FAIL: $deploy not found"; exit 1; }
# shellcheck disable=SC2016  # literal $ALL_TENANTS in the pattern
if ! grep -q '^if \[\[ "\$ALL_TENANTS" == "true" \]\]; then' "$deploy"; then
    echo "FAIL: $deploy: ALL_TENANTS branch not found — update this lint"
    fail=1
fi
# Pattern passed via ENVIRON: `awk -v` would eat the regex backslashes.
outside=$(GLOB="$glob" awk '
    /^if \[\[ "\$ALL_TENANTS" == "true" \]\]; then/ { inside = 1; next }
    inside && /^(else|elif|fi)/                   { inside = 0 }
    $0 ~ ENVIRON["GLOB"] && !/^[[:space:]]*#/ { if (inside) seen++; else printf "%d: %s\n", NR, $0 }
    END { if (seen != 1) printf "ALL_TENANTS branch has %d tenant loops, expected 1\n", seen }
' "$deploy")
if [ -n "$outside" ]; then
    echo "FAIL: $deploy iterates tenants outside the prod ALL_TENANTS branch:"
    printf '%s\n' "$outside" | sed 's/^/    /'
    fail=1
fi

# ci-deploy-app.sh is dev-only (per-app parallel steps): no tenant loops at all.
app=ci/scripts/ci-deploy-app.sh
[ -f "$app" ] || { echo "FAIL: $app not found"; exit 1; }
hits=$(grep -nE "$glob" "$app" | grep -vE '^[0-9]+:[[:space:]]*#')
if [ -n "$hits" ]; then
    echo "FAIL: $app iterates over all tenants; dev app steps must use \$E2E_TENANT:"
    printf '%s\n' "$hits" | sed 's/^/    /'
    fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS: dev CI deploy paths touch only the leased tenant"
exit "$fail"
