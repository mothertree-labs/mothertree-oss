#!/usr/bin/env bash
# Unit tests for mt_public_hosts_probeable_from_cluster (scripts/lib/common.sh):
# the decision create_env makes before deploying a tenant's public-endpoint
# Blackbox Probes. Inputs are the live ingress-nginx `use-proxy-protocol`
# ConfigMap value and whether the tenant's DNS is Cloudflare-proxied.
#
# Run: scripts/tests/test-probe-reachability.sh   (CI: .woodpecker/validate.yaml)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

PASS=0
FAIL=0

assert_rc() {
  local desc="$1" expected_rc="$2"
  shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$expected_rc" = "$rc" ]; then
    PASS=$((PASS + 1))
    echo "  ok   - $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL - $desc (expected rc $expected_rc, got $rc)"
  fi
}

echo "mt_public_hosts_probeable_from_cluster <use-proxy-protocol> <cf-proxied>"
assert_rc "prod-eu shape: PROXY protocol off, DNS-only records -> probeable" 0 \
  mt_public_hosts_probeable_from_cluster false false
assert_rc "prod shape: PROXY protocol on, Cloudflare-proxied DNS -> probeable (re-enters via NodeBalancer)" 0 \
  mt_public_hosts_probeable_from_cluster true true
assert_rc "dev shape: PROXY protocol on, DNS-only records -> NOT probeable (kube-proxy short-circuit)" 1 \
  mt_public_hosts_probeable_from_cluster true false
assert_rc "PROXY protocol off and proxied DNS -> probeable" 0 \
  mt_public_hosts_probeable_from_cluster false true
assert_rc "missing ConfigMap key is treated as off (jq default) -> probeable" 0 \
  mt_public_hosts_probeable_from_cluster "" false
assert_rc "only the literal string true enables PROXY protocol" 0 \
  mt_public_hosts_probeable_from_cluster True false

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
