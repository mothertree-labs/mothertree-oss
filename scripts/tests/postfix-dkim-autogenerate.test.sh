#!/usr/bin/env bash
# Tripwire: nothing that deploys the infra Postfix may set DKIM_AUTOGENERATE.
# boky/postfix tests it with [[ -n "$DKIM_AUTOGENERATE" ]], so even "false"
# enables key generation; with keys present, boky/postfix >= 5.2 starts rspamd
# (~290Mi vs ~30Mi) in a pod that is inbound-only and never signs.
# Repo-wide (manifests, deploy scripts, env patches), comment lines excluded.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
hits=$(git grep -n -I 'DKIM_AUTOGENERATE' -- apps scripts ci ':!scripts/tests' 2>/dev/null \
  | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [ -n "$hits" ]; then
  echo "FAIL: DKIM_AUTOGENERATE is set outside comments; any value (even \"false\") turns DKIM key generation on:"
  echo "$hits"
  exit 1
fi
echo "postfix-dkim-autogenerate: ok"
