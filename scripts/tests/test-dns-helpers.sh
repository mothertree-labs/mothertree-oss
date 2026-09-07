#!/usr/bin/env bash
# Unit tests for the public-DNS helpers in scripts/lib/common.sh:
#   mt_have_dns_resolver, mt_resolve_ipv4_verdict, mt_resolve_ipv4,
#   mt_host_resolves_to, mt_partition_hosts_by_target,
#   mt_require_hosts_resolvable, mt_http01_san_lines,
#   mt_probe_target_hosts, mt_filter_probe_targets_by_hosts
#
# These decide which hosts go into an external-DNS tenant's HTTP-01 multi-SAN
# certificate and probe list (scripts/create_env), where a single wrong SAN
# fails the whole order and a wrongly EXCLUDED live host re-issues a smaller
# certificate and breaks that host. So:
#   1. the real dig parsing + retry path runs against a fake `dig` on PATH
#      that replays every response shape (timeout rc 9, SERVFAIL, REFUSED,
#      NXDOMAIN, NODATA, CNAME chain, garbage, flaky-then-good);
#   2. the fallback backend (getent) is shown to never produce a NEGATIVE;
#   3. the partition / fail-closed logic runs against a stubbed verdict.
# No network is used.
#
# Run: scripts/tests/test-dns-helpers.sh   (CI: .woodpecker/validate.yaml)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"
export MT_RESOLVE_RETRY_BACKOFF=0

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) PASS=$((PASS + 1)); echo "  ok   - $desc" ;;
    *) FAIL=$((FAIL + 1)); echo "  FAIL - $desc"; echo "         missing:  $(printf '%q' "$needle")"; echo "         in:       $(printf '%q' "$haystack")" ;;
  esac
}

assert_rc() {
  local desc="$1" expected_rc="$2"
  shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$desc" "$expected_rc" "$rc"
}

# ---------------------------------------------------------------------------
# 1. Real dig parsing + retry path, with a fake `dig` on PATH that replays the
#    exact output shapes of dig 9.10 / 9.18 (+noall +comments +answer).
# ---------------------------------------------------------------------------
echo "mt_resolve_ipv4_verdict (fake dig on PATH)"
SHIM_DIR=$(mktemp -d)
trap 'rm -rf "$SHIM_DIR"' EXIT
export FAKE_DIG_LOG="$SHIM_DIR/dig-calls.log"
cat > "$SHIM_DIR/dig" <<'EOF'
#!/bin/sh
# Fake dig. The query name is the last plain argument; "@server" picks a
# resolver ("system" when absent). Every call is logged as "<name> <server>".
name=""
server="system"
for a; do
  case "$a" in
    @*) server="${a#@}" ;;
    +*|A) ;;
    *) name="$a" ;;
  esac
done
printf '%s %s\n' "$name" "$server" >> "${FAKE_DIG_LOG:?}"
hdr() {
  printf ';; Got answer:\n;; ->>HEADER<<- opcode: QUERY, status: %s, id: 4242\n;; flags: qr rd ra; QUERY: 1, ANSWER: %s, AUTHORITY: 0, ADDITIONAL: 1\n\n' "$1" "$2"
}
case "$name" in
  chain.tenant.example.com)
    hdr NOERROR 4
    printf ';; ANSWER SECTION:\n'
    printf 'chain.tenant.example.com.\t300\tIN\tCNAME\tlb1.prod.infra.example.net.\n'
    printf 'lb1.prod.infra.example.net.\t60\tIN\tCNAME\tlb1.prod-eu.infra.example.net.\n'
    printf 'lb1.prod-eu.infra.example.net.\t60\tIN\tA\t203.0.113.10\n'
    printf 'lb1.prod-eu.infra.example.net.\t60\tIN\tA\t203.0.113.10\n' ;;
  multi.tenant.example.com)
    hdr NOERROR 2
    printf 'multi.tenant.example.com.\t60\tIN\tA\t203.0.113.11\nmulti.tenant.example.com.\t60\tIN\tA\t203.0.113.10\n' ;;
  cname-only.tenant.example.com)
    hdr NOERROR 1
    printf 'cname-only.tenant.example.com.\t60\tIN\tCNAME\tdangling.example.net.\n' ;;
  missing.tenant.example.com)
    hdr NXDOMAIN 0 ;;
  servfail.tenant.example.com)
    hdr SERVFAIL 0 ;;
  refused.tenant.example.com)
    hdr REFUSED 0 ;;
  timeout.tenant.example.com)
    # dig 9.10 timeout: rc 9
    printf ';; connection timed out; no servers could be reached\n'
    exit 9 ;;
  modern-timeout.tenant.example.com)
    # dig 9.18 timeout: rc 9
    printf ';; communications error to 127.0.0.53#53: timed out\n;; no servers could be reached\n'
    exit 9 ;;
  flaky.tenant.example.com)
    # wedged system stub resolver; a public resolver answers
    if [ "$server" = "system" ]; then
      printf ';; connection timed out; no servers could be reached\n'
      exit 9
    fi
    hdr NOERROR 1
    printf 'flaky.tenant.example.com.\t60\tIN\tA\t203.0.113.10\n' ;;
  flaky-negative.tenant.example.com)
    # system resolver SERVFAILs; a public resolver gives a definite NXDOMAIN
    if [ "$server" = "system" ]; then
      hdr SERVFAIL 0
      exit 0
    fi
    hdr NXDOMAIN 0 ;;
  garbage.tenant.example.com)
    printf 'this is not dig output\n' ;;
  *)
    hdr NXDOMAIN 0 ;;
esac
exit 0
EOF
chmod +x "$SHIM_DIR/dig"

# Run the genuine functions (re-sourced, so the stubs defined later cannot
# leak in) in a subshell whose PATH finds the shim first. Prints
# "<rc> <verdict> <ips-comma-joined>".
real_verdict() {
  (
    unset _MT_COMMON_LOADED
    PATH="$SHIM_DIR:$PATH"
    export MT_RESOLVER_BACKEND="${2:-dig}" MT_RESOLVE_RETRY_BACKOFF=0
    # shellcheck source=../lib/common.sh
    source "${REPO_ROOT}/scripts/lib/common.sh"
    rc=0
    mt_resolve_ipv4_verdict "$1" || rc=$?
    printf '%s %s %s\n' "$rc" "$MT_RESOLVE_VERDICT" "$(printf '%s' "$MT_RESOLVE_IPS" | tr '\n' ',')"
  )
}
real_reason() {
  (
    unset _MT_COMMON_LOADED
    PATH="$SHIM_DIR:$PATH"
    export MT_RESOLVER_BACKEND="${2:-dig}" MT_RESOLVE_RETRY_BACKOFF=0
    # shellcheck source=../lib/common.sh
    source "${REPO_ROOT}/scripts/lib/common.sh"
    mt_resolve_ipv4_verdict "$1" || true
    printf '%s\n' "$MT_RESOLVE_REASON"
  )
}
real_ipv4() {
  (
    unset _MT_COMMON_LOADED
    PATH="$SHIM_DIR:$PATH"
    export MT_RESOLVER_BACKEND=dig MT_RESOLVE_RETRY_BACKOFF=0
    # shellcheck source=../lib/common.sh
    source "${REPO_ROOT}/scripts/lib/common.sh"
    mt_resolve_ipv4 "$1"
  )
}
calls_for() { grep -c "^$1 " "$FAKE_DIG_LOG" || true; }
servers_for() { grep "^$1 " "$FAKE_DIG_LOG" | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//'; }

: > "$FAKE_DIG_LOG"
assert_eq "CNAME chain -> RESOLVED, only the (deduped) IPv4" "0 RESOLVED 203.0.113.10" "$(real_verdict chain.tenant.example.com)"
assert_eq "one attempt when the first answer is definite" "1" "$(calls_for chain.tenant.example.com)"
assert_eq "several A records -> all of them, sorted" "0 RESOLVED 203.0.113.10,203.0.113.11" "$(real_verdict multi.tenant.example.com)"
assert_eq "NOERROR with CNAME only (NODATA) -> NEGATIVE, rc 1" "1 NEGATIVE " "$(real_verdict cname-only.tenant.example.com)"
assert_contains "NODATA reason says so" "NODATA" "$(real_reason cname-only.tenant.example.com)"
assert_eq "NXDOMAIN -> NEGATIVE, rc 1" "1 NEGATIVE " "$(real_verdict missing.tenant.example.com)"
assert_contains "NXDOMAIN reason says so" "NXDOMAIN" "$(real_reason missing.tenant.example.com)"
: > "$FAKE_DIG_LOG"
real_verdict missing.tenant.example.com >/dev/null
assert_eq "a definite NEGATIVE is not retried" "1" "$(calls_for missing.tenant.example.com)"

: > "$FAKE_DIG_LOG"
assert_eq "SERVFAIL -> ERROR, rc 2 (never NEGATIVE)" "2 ERROR " "$(real_verdict servfail.tenant.example.com)"
assert_eq "ERROR is retried: system, 1.1.1.1, 8.8.8.8, system" "system 1.1.1.1 8.8.8.8 system" "$(servers_for servfail.tenant.example.com)"
assert_contains "ERROR reason lists every attempt" "attempt 4: dig status SERVFAIL" "$(real_reason servfail.tenant.example.com)"
assert_eq "REFUSED -> ERROR" "2 ERROR " "$(real_verdict refused.tenant.example.com)"
assert_eq "dig 9.10 timeout (rc 9) -> ERROR, rc 2 — NOT 'does not resolve'" "2 ERROR " "$(real_verdict timeout.tenant.example.com)"
assert_contains "timeout reason carries dig's exit code and text" "dig exit 9: connection timed out; no servers could be reached" "$(real_reason timeout.tenant.example.com)"
assert_eq "dig 9.18 timeout (rc 9, two-line text) -> ERROR" "2 ERROR " "$(real_verdict modern-timeout.tenant.example.com)"
assert_eq "unparsable output -> ERROR" "2 ERROR " "$(real_verdict garbage.tenant.example.com)"
assert_contains "unparsable reason says so" "unparsable dig output" "$(real_reason garbage.tenant.example.com)"
assert_eq "empty hostname -> ERROR" "2 ERROR " "$(real_verdict "")"

: > "$FAKE_DIG_LOG"
assert_eq "wedged system resolver, public resolver answers -> RESOLVED on the retry" "0 RESOLVED 203.0.113.10" "$(real_verdict flaky.tenant.example.com)"
assert_eq "retry-then-RESOLVED stops after the public resolver's answer" "system 1.1.1.1" "$(servers_for flaky.tenant.example.com)"
assert_eq "system SERVFAIL, public resolver NXDOMAIN -> NEGATIVE (definite answer accepted)" "1 NEGATIVE " "$(real_verdict flaky-negative.tenant.example.com)"

: > "$FAKE_DIG_LOG"
assert_eq "no public resolvers configured -> still 4 attempts on the system resolver" "system system system system" \
  "$(MT_RESOLVE_PUBLIC_RESOLVERS="" real_verdict servfail.tenant.example.com >/dev/null; servers_for servfail.tenant.example.com)"

echo "mt_resolve_ipv4 wrapper"
assert_eq "prints the IPv4s on RESOLVED" "203.0.113.10" "$(real_ipv4 chain.tenant.example.com)"
assert_rc "rc 1 on NEGATIVE" 1 real_ipv4 missing.tenant.example.com
assert_rc "rc 2 on ERROR (timeout)" 2 real_ipv4 timeout.tenant.example.com
assert_eq "prints nothing on ERROR" "" "$(real_ipv4 timeout.tenant.example.com || true)"

echo "mt_have_dns_resolver"
assert_rc "finds the shim dig" 0 \
  env PATH="$SHIM_DIR:$PATH" bash -c "unset _MT_COMMON_LOADED; source '${REPO_ROOT}/scripts/lib/common.sh'; mt_have_dns_resolver"
assert_rc "backend none -> no resolver" 1 \
  env MT_RESOLVER_BACKEND=none bash -c "unset _MT_COMMON_LOADED; source '${REPO_ROOT}/scripts/lib/common.sh'; mt_have_dns_resolver"

# ---------------------------------------------------------------------------
# 1b. Fallback backend (getent): an answer is RESOLVED, a non-answer is ERROR
#     — never NEGATIVE, because getent cannot tell NXDOMAIN from a timeout.
# ---------------------------------------------------------------------------
echo "fallback backend (fake getent on PATH)"
cat > "$SHIM_DIR/getent" <<'EOF'
#!/bin/sh
# getent ahostsv4 <name>: one line per socket type, address first.
case "$2" in
  ok.tenant.example.com)
    printf '203.0.113.10 STREAM ok.tenant.example.com\n203.0.113.10 DGRAM \n203.0.113.10 RAW \n' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$SHIM_DIR/getent"
assert_eq "getent answer -> RESOLVED (deduped)" "0 RESOLVED 203.0.113.10" "$(real_verdict ok.tenant.example.com getent)"
assert_eq "getent non-answer -> ERROR, rc 2 (not NEGATIVE)" "2 ERROR " "$(real_verdict missing.tenant.example.com getent)"
assert_contains "fallback ERROR reason explains why it is not a negative" "cannot tell NXDOMAIN from a resolver failure" "$(real_reason missing.tenant.example.com getent)"
assert_eq "backend none -> ERROR immediately" "2 ERROR " "$(real_verdict ok.tenant.example.com none)"
assert_contains "backend none reason" "no DNS resolver CLI" "$(real_reason ok.tenant.example.com none)"

# ---------------------------------------------------------------------------
# 2. Partition + fail-closed logic against a stubbed verdict. Our LB is
#    203.0.113.10. The stub replaces mt_resolve_ipv4_verdict in THIS shell.
# ---------------------------------------------------------------------------
echo "mt_host_resolves_to / mt_partition_hosts_by_target / mt_require_hosts_resolvable (stubbed verdict)"
OUR_LB="203.0.113.10"
mt_resolve_ipv4_verdict() {
  MT_RESOLVE_IPS=""
  MT_RESOLVE_REASON=""
  case "$1" in
    matrix.tenant.example.com|auth.tenant.example.com)
      MT_RESOLVE_VERDICT=RESOLVED; MT_RESOLVE_IPS='203.0.113.10'; return 0 ;;
    docs.tenant.example.com)
      MT_RESOLVE_VERDICT=RESOLVED; MT_RESOLVE_IPS=$'203.0.113.10\n203.0.113.11'; return 0 ;;   # multi-A, one is us
    files.tenant.example.com)
      MT_RESOLVE_VERDICT=RESOLVED; MT_RESOLVE_IPS='198.51.100.7'; return 0 ;;                  # CNAME to the tenant's old host
    admin.tenant.example.com|account.tenant.example.com)
      MT_RESOLVE_VERDICT=NEGATIVE; MT_RESOLVE_REASON='NXDOMAIN'; return 1 ;;
    nodata.tenant.example.com)
      MT_RESOLVE_VERDICT=NEGATIVE; MT_RESOLVE_REASON='no A record (NODATA)'; return 1 ;;
    wedged.tenant.example.com)
      MT_RESOLVE_VERDICT=ERROR; MT_RESOLVE_REASON='giving up after 4 attempts — attempt 1: dig exit 9: connection timed out; no servers could be reached; ...'; return 2 ;;
    *)
      MT_RESOLVE_VERDICT=ERROR; MT_RESOLVE_REASON='unexpected host in test'; return 2 ;;
  esac
}

assert_rc "host pointing at our LB -> 0" 0 mt_host_resolves_to matrix.tenant.example.com "$OUR_LB"
assert_rc "host pointing elsewhere -> 1 (resolving is not enough)" 1 mt_host_resolves_to files.tenant.example.com "$OUR_LB"
assert_rc "NXDOMAIN host -> 1" 1 mt_host_resolves_to admin.tenant.example.com "$OUR_LB"
assert_rc "resolver ERROR -> 2 (unknown), never 1" 2 mt_host_resolves_to wedged.tenant.example.com "$OUR_LB"
assert_rc "any one of several A records matching is enough" 0 mt_host_resolves_to docs.tenant.example.com "203.0.113.11"
assert_rc "target list may be comma-separated" 0 mt_host_resolves_to matrix.tenant.example.com "198.51.100.1,$OUR_LB"
assert_rc "target list may be space-separated" 0 mt_host_resolves_to matrix.tenant.example.com "198.51.100.1 $OUR_LB"
assert_rc "no target IP matches -> 1" 1 mt_host_resolves_to matrix.tenant.example.com "198.51.100.1,198.51.100.2"

mt_partition_hosts_by_target "$OUR_LB" \
  matrix.tenant.example.com auth.tenant.example.com files.tenant.example.com \
  docs.tenant.example.com admin.tenant.example.com wedged.tenant.example.com \
  nodata.tenant.example.com account.tenant.example.com
assert_eq "mixed: hosts at our LB, in input order" \
  "matrix.tenant.example.com auth.tenant.example.com docs.tenant.example.com" "$MT_HOSTS_AT_TARGET"
assert_eq "mixed: definitely-not hosts (elsewhere, NXDOMAIN, NODATA), in input order" \
  "files.tenant.example.com admin.tenant.example.com nodata.tenant.example.com account.tenant.example.com" "$MT_HOSTS_NOT_AT_TARGET"
assert_eq "mixed: the ERROR host lands in the UNRESOLVABLE bucket, not in NOT_AT_TARGET" \
  "wedged.tenant.example.com" "$MT_HOSTS_UNRESOLVABLE"
assert_eq "mixed: one detail line per excluded host, saying why" \
  $'files.tenant.example.com: resolves to 198.51.100.7 (not our ingress)\nadmin.tenant.example.com: does not resolve (NXDOMAIN)\nnodata.tenant.example.com: does not resolve (no A record (NODATA))\naccount.tenant.example.com: does not resolve (NXDOMAIN)\n' \
  "$MT_HOSTS_NOT_AT_TARGET_DETAIL"
assert_contains "mixed: unresolvable detail carries the resolver's reason" \
  "wedged.tenant.example.com: could not be resolved (giving up after 4 attempts" "$MT_HOSTS_UNRESOLVABLE_DETAIL"
assert_rc "mt_require_hosts_resolvable -> 1 while an UNRESOLVABLE host exists" 1 \
  mt_require_hosts_resolvable "test hosts"
assert_contains "mt_require_hosts_resolvable names the host and the reason" \
  "wedged.tenant.example.com: could not be resolved" "$(mt_require_hosts_resolvable "test hosts" 2>&1 || true)"
assert_contains "mt_require_hosts_resolvable says nothing was changed" \
  "nothing was changed" "$(mt_require_hosts_resolvable "test hosts" 2>&1 || true)"

mt_partition_hosts_by_target "$OUR_LB" matrix.tenant.example.com auth.tenant.example.com
assert_eq "all at target: nothing excluded" "" "$MT_HOSTS_NOT_AT_TARGET"
assert_eq "all at target: no detail lines" "" "$MT_HOSTS_NOT_AT_TARGET_DETAIL"
assert_eq "all at target: nothing unresolvable" "" "$MT_HOSTS_UNRESOLVABLE"
assert_eq "all at target: every host kept" "matrix.tenant.example.com auth.tenant.example.com" "$MT_HOSTS_AT_TARGET"
assert_rc "mt_require_hosts_resolvable -> 0 when every verdict is definite" 0 mt_require_hosts_resolvable "test hosts"
assert_eq "mt_require_hosts_resolvable is silent when it passes" "" "$(mt_require_hosts_resolvable "test hosts" 2>&1)"

mt_partition_hosts_by_target "$OUR_LB" admin.tenant.example.com files.tenant.example.com
assert_eq "none at target: empty include list (caller must fail fast)" "" "$MT_HOSTS_AT_TARGET"
assert_eq "none at target: every host excluded" "admin.tenant.example.com files.tenant.example.com" "$MT_HOSTS_NOT_AT_TARGET"

# The create_env call-site sequence: partition, then require resolvable
# BEFORE anything is applied. With one live host and one wedged lookup the
# deploy must abort (exit 1) — the wedged host is never treated as excluded.
create_env_shape() {
  (
    set -euo pipefail
    mt_partition_hosts_by_target "$OUR_LB" matrix.tenant.example.com wedged.tenant.example.com
    mt_require_hosts_resolvable "HTTP-01 SAN candidates" || exit 1
    echo "WOULD APPLY SANs: $MT_HOSTS_AT_TARGET"
  )
}
assert_rc "create_env shape: UNRESOLVABLE host -> deploy aborts (exit 1)" 1 create_env_shape
assert_eq "create_env shape: nothing is applied after the abort" "" "$(create_env_shape 2>/dev/null | grep 'WOULD APPLY' || true)"
mt_partition_hosts_by_target "$OUR_LB" matrix.tenant.example.com wedged.tenant.example.com
assert_eq "create_env shape: the wedged host is not in the excluded list either" "" "$MT_HOSTS_NOT_AT_TARGET"

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
