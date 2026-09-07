#!/usr/bin/env bash
# Unit tests for the public-DNS helpers in scripts/lib/common.sh:
#   mt_have_dns_resolver, mt_resolve_ipv4, mt_host_resolves_to,
#   mt_partition_hosts_by_target, mt_http01_san_lines
#
# These decide which hosts go into an external-DNS tenant's HTTP-01 multi-SAN
# certificate (scripts/create_env), where a single wrong SAN fails the whole
# order — so the partition logic is tested against a stubbed resolver (no
# network) and the real parsing path is tested with a fake `dig` on PATH.
#
# Run: scripts/tests/test-dns-helpers.sh   (CI: .woodpecker/validate.yaml)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  ok   - $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL - $desc"
    echo "         expected: $(printf '%q' "$expected")"
    echo "         actual:   $(printf '%q' "$actual")"
  fi
}

assert_rc() {
  local desc="$1" expected_rc="$2"
  shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$desc" "$expected_rc" "$rc"
}

# ---------------------------------------------------------------------------
# 1. Real parsing path: mt_resolve_ipv4 with a fake `dig` on PATH.
#    dig +short prints the CNAME chain before the A records; only IPv4
#    literals may come out, de-duplicated and sorted.
# ---------------------------------------------------------------------------
echo "mt_resolve_ipv4 (fake dig on PATH)"
SHIM_DIR=$(mktemp -d)
trap 'rm -rf "$SHIM_DIR"' EXIT
cat > "$SHIM_DIR/dig" <<'EOF'
#!/bin/sh
# Last argument is the name. Mimic `dig +short A <name>` output shapes.
for name; do :; done
case "$name" in
  chain.tenant.example.com)
    printf 'lb1.prod.infra.example.net.\nlb1.prod-eu.infra.example.net.\n203.0.113.10\n203.0.113.10\n' ;;
  multi.tenant.example.com)
    printf '203.0.113.11\n203.0.113.10\n' ;;
  cname-only.tenant.example.com)
    printf 'dangling.example.net.\n' ;;
  *) ;;
esac
exit 0
EOF
chmod +x "$SHIM_DIR/dig"

# Run the genuine function (re-sourced, so the stub defined below cannot leak
# in) in a subshell whose PATH finds the shim first.
real_resolve() {
  (
    unset _MT_COMMON_LOADED
    PATH="$SHIM_DIR:$PATH"
    # shellcheck source=../lib/common.sh
    source "${REPO_ROOT}/scripts/lib/common.sh"
    mt_resolve_ipv4 "$1"
  )
}
assert_eq "follows a CNAME chain and prints only the (deduped) IPv4" \
  "203.0.113.10" "$(real_resolve chain.tenant.example.com)"
assert_eq "prints every A record, sorted, one per line" \
  $'203.0.113.10\n203.0.113.11' "$(real_resolve multi.tenant.example.com)"
assert_rc "a CNAME that never reaches an A record does not resolve (rc 1)" 1 \
  real_resolve cname-only.tenant.example.com
assert_rc "NXDOMAIN (empty dig output) does not resolve (rc 1)" 1 \
  real_resolve missing.tenant.example.com
assert_rc "empty hostname is rejected (rc 1)" 1 real_resolve ""
assert_rc "mt_have_dns_resolver finds the shim" 0 \
  env PATH="$SHIM_DIR:$PATH" bash -c "unset _MT_COMMON_LOADED; source '${REPO_ROOT}/scripts/lib/common.sh'; mt_have_dns_resolver"

# ---------------------------------------------------------------------------
# 2. Partition logic against a stubbed resolver (a fake tenant zone).
#    Our ingress LB is 203.0.113.10.
# ---------------------------------------------------------------------------
echo "mt_host_resolves_to / mt_partition_hosts_by_target (stubbed resolver)"
OUR_LB="203.0.113.10"
mt_resolve_ipv4() {
  case "$1" in
    matrix.tenant.example.com|auth.tenant.example.com) printf '203.0.113.10\n' ;;
    docs.tenant.example.com)  printf '203.0.113.10\n203.0.113.11\n' ;;   # multi-A, one is us
    files.tenant.example.com) printf '198.51.100.7\n' ;;                 # CNAME to the tenant's old host
    *) return 1 ;;                                                       # NXDOMAIN
  esac
}

assert_rc "host pointing at our LB -> 0" 0 mt_host_resolves_to matrix.tenant.example.com "$OUR_LB"
assert_rc "host pointing elsewhere -> 1 (resolving is not enough)" 1 mt_host_resolves_to files.tenant.example.com "$OUR_LB"
assert_rc "NXDOMAIN host -> 1" 1 mt_host_resolves_to admin.tenant.example.com "$OUR_LB"
assert_rc "any one of several A records matching is enough" 0 mt_host_resolves_to docs.tenant.example.com "203.0.113.11"
assert_rc "target list may be comma-separated" 0 mt_host_resolves_to matrix.tenant.example.com "198.51.100.1,$OUR_LB"
assert_rc "target list may be space-separated" 0 mt_host_resolves_to matrix.tenant.example.com "198.51.100.1 $OUR_LB"
assert_rc "no target IP matches -> 1" 1 mt_host_resolves_to matrix.tenant.example.com "198.51.100.1,198.51.100.2"

mt_partition_hosts_by_target "$OUR_LB" \
  matrix.tenant.example.com auth.tenant.example.com files.tenant.example.com \
  docs.tenant.example.com admin.tenant.example.com account.tenant.example.com
assert_eq "mixed: hosts at our LB, in input order" \
  "matrix.tenant.example.com auth.tenant.example.com docs.tenant.example.com" "$MT_HOSTS_AT_TARGET"
assert_eq "mixed: hosts not at our LB (elsewhere + NXDOMAIN), in input order" \
  "files.tenant.example.com admin.tenant.example.com account.tenant.example.com" "$MT_HOSTS_NOT_AT_TARGET"
assert_eq "mixed: one detail line per excluded host, saying why" \
  $'files.tenant.example.com: resolves to 198.51.100.7 (not our ingress)\nadmin.tenant.example.com: does not resolve\naccount.tenant.example.com: does not resolve\n' \
  "$MT_HOSTS_NOT_AT_TARGET_DETAIL"

mt_partition_hosts_by_target "$OUR_LB" matrix.tenant.example.com auth.tenant.example.com
assert_eq "all at target: nothing excluded" "" "$MT_HOSTS_NOT_AT_TARGET"
assert_eq "all at target: no detail lines" "" "$MT_HOSTS_NOT_AT_TARGET_DETAIL"
assert_eq "all at target: every host kept" "matrix.tenant.example.com auth.tenant.example.com" "$MT_HOSTS_AT_TARGET"

mt_partition_hosts_by_target "$OUR_LB" admin.tenant.example.com files.tenant.example.com
assert_eq "none at target: empty include list (caller must fail fast)" "" "$MT_HOSTS_AT_TARGET"
assert_eq "none at target: every host excluded" "admin.tenant.example.com files.tenant.example.com" "$MT_HOSTS_NOT_AT_TARGET"

# Word-splitting call shape used by create_env (unquoted space-separated list).
CANDIDATES=" matrix.tenant.example.com admin.tenant.example.com"
# shellcheck disable=SC2086
mt_partition_hosts_by_target "$OUR_LB" $CANDIDATES
assert_eq "create_env call shape (leading space, unquoted) works" "matrix.tenant.example.com" "$MT_HOSTS_AT_TARGET"

# ---------------------------------------------------------------------------
# 3. SAN block rendering for certificate-http01.yaml.tpl.
# ---------------------------------------------------------------------------
echo "mt_http01_san_lines"
assert_eq "renders one 4-space-indented quoted list item per host" \
  $'    - "matrix.tenant.example.com"\n    - "auth.tenant.example.com"' \
  "$(mt_http01_san_lines "matrix.tenant.example.com auth.tenant.example.com")"
assert_eq "single host" '    - "auth.tenant.example.com"' "$(mt_http01_san_lines "auth.tenant.example.com")"
assert_eq "empty list renders nothing" "" "$(mt_http01_san_lines "")"

# ---------------------------------------------------------------------------
# 4. Probe-target filtering for external-DNS tenants (ENDPOINT_PROBE_TARGETS
#    is a block of `        - https://host/path` lines built by create_env).
# ---------------------------------------------------------------------------
echo "mt_probe_target_hosts / mt_filter_probe_targets_by_hosts"
TARGETS=$'        - https://matrix.tenant.example.com/\n        - https://files.tenant.example.com/status.php\n        - https://admin.tenant.example.com/\n        - https://files.tenant.example.com/\n'
assert_eq "unique hosts, sorted, space-separated" \
  "admin.tenant.example.com files.tenant.example.com matrix.tenant.example.com" \
  "$(mt_probe_target_hosts "$TARGETS")"
assert_eq "keeps every line whose host is allowed, in original order, and drops the rest" \
  $'        - https://matrix.tenant.example.com/\n        - https://files.tenant.example.com/status.php\n        - https://files.tenant.example.com/' \
  "$(mt_filter_probe_targets_by_hosts "$TARGETS" "matrix.tenant.example.com files.tenant.example.com")"
assert_eq "no allowed hosts -> nothing kept" "" "$(mt_filter_probe_targets_by_hosts "$TARGETS" "")"
assert_eq "empty block -> nothing" "" "$(mt_filter_probe_targets_by_hosts "" "matrix.tenant.example.com")"
assert_eq "host match is exact (no prefix/suffix matching)" "" \
  "$(mt_filter_probe_targets_by_hosts "$TARGETS" "tenant.example.com files.tenant.example.com.evil")"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
