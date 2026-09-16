#!/usr/bin/env bash
# Unit tests for scripts/verify-reflector's source discovery and row consumer:
# the wire format between _list_sources / _tenant_source and
# _reflector_check_rows. Driven by a fake kubectl — no cluster. The script
# guards `main` behind a BASH_SOURCE check so it can be sourced here.
#
# Why this file exists: the all-tenants path shipped with the producer emitting
# SIX tab-separated fields (its jsonpath also selects reflection-auto-enabled,
# to filter on) while the consumer read FIVE. Every value landed one column
# late, so `selectors` held the allowed-namespaces list and every healthy
# source was reported as "carries a *-namespaces-selector annotation"
# (pipeline 2233's check-health). Nothing covered that path: the suite tested
# mt_wait_for_reflection and the canary, and the per-tenant producer — which
# prints five — was the one used by create_env and the CI gate, so the bug
# only ever fired on `verify-reflector` without -t.
#
# Run: scripts/tests/test-verify-reflector.sh   (CI: ci/scripts/shell-unit-tests.sh)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../verify-reflector
source "${REPO_ROOT}/scripts/verify-reflector"
set +e   # the script enables -e for its own run; tests assert on non-zero returns

PASS=0; FAIL=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "  ok   - $1"; else FAIL=$((FAIL + 1)); echo "  FAIL - $1 (expected [$2] got [$3])"; fi
}
has() {  # has <description> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" yes yes ;; *) check "$1" "contains [$2]" "$(printf '%s' "$3" | tr '\n' '|')" ;; esac
}
lacks() {  # lacks <description> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "no [$2]" "$(printf '%s' "$3" | tr '\n' '|')" ;; *) check "$1" yes yes ;; esac
}
T=$'\t'

# --- the fixture, and its provenance ----------------------------------------
# These rows are what real kubectl renders for _list_sources' jsonpath. Derived
# (no cluster) with the annotation set the live dev wildcard Secrets carry —
# reflection-allowed, reflection-allowed-namespaces, reflection-auto-enabled,
# reflection-auto-namespaces, and NO selector annotation:
#
#   ANN='reflector\.v1\.k8s\.emberstack\.com'
#   kubectl create secret generic wildcard-tls-x -n tn-x-matrix \
#       --from-literal=tls.key=SUPERSECRET --dry-run=client -o yaml \
#     | kubectl annotate --local -f - -o jsonpath='<the per-item part of the path>' \
#         reflector.v1.k8s.emberstack.com/reflection-allowed=true \
#         reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces=tn-x-mail,infra-auth \
#         reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
#         reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=tn-x-mail,infra-auth
#
# → six fields: namespace, name, auto-enabled, auto-namespaces,
#   allowed-namespaces, selectors(empty); and SUPERSECRET appears nowhere.
# The live dev cluster renders the same NF=6 for its real sources.
FIXTURE_HEALTHY="tn-x-matrix${T}wildcard-tls-x${T}true${T}tn-x-mail,infra-auth${T}tn-x-mail,infra-auth${T}"
FIXTURE_NOT_AUTO="tn-x-matrix${T}apex-tls-x${T}${T}${T}${T}"
FIXTURE_SELECTOR="tn-y-matrix${T}wildcard-tls-y${T}true${T}tn-y-mail${T}tn-y-mail${T}env=prod"
FIXTURE_EMPTY_AUTO="tn-z-matrix${T}wildcard-tls-z${T}true${T}${T}tn-z-mail${T}"
FIXTURE_EMPTY_ALLOWED="tn-w-matrix${T}wildcard-tls-w${T}true${T}tn-w-mail${T}${T}"

# The fixture must keep matching what the jsonpath renders: if the path grows or
# loses a column, this assertion fails before the ones that depend on it.
check "fixture: real-kubectl row has 6 fields" 6 "$(printf '%s\n' "$FIXTURE_HEALTHY" | awk -F'\t' '{print NF}')"
check "fixture: field 3 is the auto-enabled flag" true "$(printf '%s\n' "$FIXTURE_HEALTHY" | awk -F'\t' '{print $3}')"
check "fixture: field 4 is the auto-namespaces list" "tn-x-mail,infra-auth" "$(printf '%s\n' "$FIXTURE_HEALTHY" | awk -F'\t' '{print $4}')"
check "fixture: field 6 (selectors) is empty" "" "$(printf '%s\n' "$FIXTURE_HEALTHY" | awk -F'\t' '{print $6}')"

# --- fake kubectl ------------------------------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -u
printf '%s\n' "kubectl $*" >> "$MT_TEST_CALLS"
case " $* " in
    *" get secrets -A "*)  cat "$MT_TEST_LISTING"; exit 0 ;;
    *" get secret "*)
        name=$3; ns=$5
        # Real kubectl: --ignore-not-found -o name is rc 0 + empty for an absent
        # object (that is how _mt_secret_meta tells MISSING from UNREADABLE),
        # while a jsonpath read of an absent object is a NotFound error.
        case " $* " in *" --ignore-not-found -o name "*)
            [ -f "$MT_TEST_STATE/$ns.$name.unreadable" ] && { echo "Unable to connect to the server" >&2; exit 1; }
            [ -f "$MT_TEST_STATE/$ns.$name.rv" ] && echo "secret/$name"
            exit 0 ;;
        esac
        [ -f "$MT_TEST_STATE/$ns.$name.unreadable" ] && { echo "Unable to connect to the server" >&2; exit 1; }
        [ -f "$MT_TEST_STATE/$ns.$name.rv" ] || { echo "Error from server (NotFound): secrets \"$name\" not found" >&2; exit 1; }
        path=${7#jsonpath=}
        case "$path" in
            *resourceVersion*)                  cat "$MT_TEST_STATE/$ns.$name.rv" 2>/dev/null ;;
            *reflection-auto-namespaces-selector*) cat "$MT_TEST_STATE/$ns.$name.sel" 2>/dev/null ;;
            *reflection-auto-namespaces*)       cat "$MT_TEST_STATE/$ns.$name.auto" 2>/dev/null ;;
            *reflection-allowed-namespaces*)    cat "$MT_TEST_STATE/$ns.$name.allowed" 2>/dev/null ;;
            *) echo "fake-kubectl: unscripted jsonpath $path" >&2; exit 99 ;;
        esac
        exit 0 ;;
esac
echo "fake-kubectl: unscripted call: $*" >&2; exit 99
FAKE
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH"
export MT_TEST_CALLS="$TMP/calls" MT_TEST_LISTING="$TMP/listing" MT_TEST_STATE="$TMP/state"
reset() { rm -rf "$MT_TEST_STATE"; mkdir -p "$MT_TEST_STATE"; : > "$MT_TEST_CALLS"; : > "$MT_TEST_LISTING"; }
listing() { printf '%s\n' "$@" > "$MT_TEST_LISTING"; }

# --- _list_sources: 6 rendered columns in, 5 documented fields out -----------
reset; listing "$FIXTURE_HEALTHY" "$FIXTURE_NOT_AUTO" "$FIXTURE_SELECTOR"
rows=$(_list_sources)
check "_list_sources: every row has exactly 5 fields" "5 5" "$(printf '%s\n' "$rows" | awk -F'\t' '{printf "%s ", NF}' | sed 's/ $//')"
check "_list_sources: drops the non auto-enabled Secret" 2 "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
lacks "_list_sources: the dropped Secret is really gone" "apex-tls-x" "$rows"
# THE regression assertion: field 3 is the namespace list, not the filter flag.
check "_list_sources: field 3 is auto-namespaces, NOT 'true'" "tn-x-mail,infra-auth" "$(printf '%s\n' "$rows" | awk -F'\t' 'NR==1{print $3}')"
check "_list_sources: field 4 is allowed-namespaces" "tn-x-mail,infra-auth" "$(printf '%s\n' "$rows" | awk -F'\t' 'NR==1{print $4}')"
check "_list_sources: field 5 (no selector) is the placeholder" "$_MT_REFLECTOR_EMPTY" "$(printf '%s\n' "$rows" | awk -F'\t' 'NR==1{print $5}')"
check "_list_sources: a real selector reaches field 5" "env=prod" "$(printf '%s\n' "$rows" | awk -F'\t' 'NR==2{print $5}')"
check "_list_sources: ns/name keep fields 1 and 2 (canary positive control keys on them)" "tn-x-matrix wildcard-tls-x" "$(printf '%s\n' "$rows" | awk -F'\t' 'NR==1{print $1, $2}')"
# An empty middle field must not collapse: bash `read` treats tab as IFS whitespace.
reset; listing "$FIXTURE_EMPTY_AUTO"
check "_list_sources: empty auto-namespaces becomes the placeholder, count preserved" "5" "$(_list_sources | awk -F'\t' '{print NF}')"
check "_list_sources: ...and lands in field 3" "$_MT_REFLECTOR_EMPTY" "$(_list_sources | awk -F'\t' '{print $3}')"

# --- _reflector_source_ok ----------------------------------------------------
ok_out=$(_reflector_source_ok tn-x-matrix wildcard-tls-x "tn-x-mail,infra-auth" "tn-x-mail,infra-auth" "$_MT_REFLECTOR_EMPTY" 2>&1); ok_rc=$?
check "verdict: healthy source passes" 0 "$ok_rc"
check "verdict: healthy source says nothing" "" "$ok_out"
out=$(_reflector_source_ok tn-y-matrix wildcard-tls-y "tn-y-mail" "tn-y-mail" "env=prod" 2>&1); rc=$?
check "verdict: selector annotation flagged" 1 "$rc"; has "verdict: selector message" "namespaces-selector" "$out"
out=$(_reflector_source_ok tn-z-matrix wildcard-tls-z "$_MT_REFLECTOR_EMPTY" "tn-z-mail" "$_MT_REFLECTOR_EMPTY" 2>&1); rc=$?
check "verdict: empty auto list flagged" 1 "$rc"; has "verdict: empty auto message" "empty reflection-auto-namespaces" "$out"
out=$(_reflector_source_ok tn-w-matrix wildcard-tls-w "tn-w-mail" "$_MT_REFLECTOR_EMPTY" "$_MT_REFLECTOR_EMPTY" 2>&1); rc=$?
check "verdict: empty allowed list flagged" 1 "$rc"; has "verdict: empty allowed message" "empty reflection-allowed-namespaces" "$out"
out=$(_reflector_source_ok tn-a-matrix wildcard-tls-a "tn-a-mail,tn-a-docs" "tn-a-mail" "$_MT_REFLECTOR_EMPTY" 2>&1); rc=$?
check "verdict: auto != allowed flagged" 1 "$rc"; has "verdict: mismatch names both" "differs from reflection-allowed-namespaces" "$out"
out=$(_reflector_source_ok tn-b-matrix wildcard-tls-b "tn-b-*" "tn-b-*" "$_MT_REFLECTOR_EMPTY" 2>&1); rc=$?
check "verdict: regex-ish entry flagged" 1 "$rc"; has "verdict: names the bad entry" "tn-b-*" "$out"
out=$(_reflector_source_ok "$_MT_REFLECTOR_EMPTY" wildcard-tls-c "tn-c-mail" "tn-c-mail" "$_MT_REFLECTOR_EMPTY" 2>&1); rc=$?
check "verdict: placeholder namespace is an internal error" 1 "$rc"; has "verdict: internal message" "no namespace/name" "$out"
# The placeholder must be DECODED before the charset check, or `-` would be
# waited on as a namespace literally named "-".
out=$(_reflector_source_ok tn-d-matrix wildcard-tls-d "$_MT_REFLECTOR_EMPTY" "$_MT_REFLECTOR_EMPTY" "$_MT_REFLECTOR_EMPTY" 2>&1)
lacks "verdict: placeholder never treated as a namespace" "lists '-'" "$out"

# --- _reflector_check_rows ---------------------------------------------------
# Stub the mirror wait: this file is about parsing (mt_wait_for_reflection has
# its own 237 assertions in scripts/lib/tests/mt-wait-for-reflection.test.sh).
WAITED=""
mt_wait_for_reflection() { WAITED="${WAITED}${WAITED:+ }$1/$2->$3"; [ "${STUB_WAIT_RC:-0}" -eq 0 ]; }
# _reflector_check_rows reports through globals, so it must NOT run in a
# command substitution — a subshell would swallow the counters (the same trap
# as piping into mt_apply, #644). Capture its output through a file instead.
run_rows() { WAITED=""; _reflector_check_rows 0 <<< "$1" > "$TMP/rows.out" 2>&1; out=$(cat "$TMP/rows.out"); }

run_rows "$(reset; listing "$FIXTURE_HEALTHY"; _list_sources)"
check "rows: healthy source → 0 failures" 0 "$MT_REFLECTOR_FAILURES"
check "rows: healthy source → 1 checked" 1 "$MT_REFLECTOR_CHECKED"
check "rows: waited on the right target list" "tn-x-matrix/wildcard-tls-x->tn-x-mail,infra-auth" "$WAITED"
lacks "rows: no false selector finding" "namespaces-selector" "$out"

run_rows "$(reset; listing "$FIXTURE_HEALTHY" "$FIXTURE_SELECTOR"; _list_sources)"
check "rows: mixed listing → 1 failure" 1 "$MT_REFLECTOR_FAILURES"
check "rows: mixed listing → 2 checked" 2 "$MT_REFLECTOR_CHECKED"
check "rows: only the healthy source was waited on" "tn-x-matrix/wildcard-tls-x->tn-x-mail,infra-auth" "$WAITED"
has "rows: the selector source is the one flagged" "tn-y-matrix/wildcard-tls-y carries" "$out"

# A row with the OLD six-field shape must be an internal error, not a finding.
# Both shapes of the old producer's row: the last column empty (what a Secret
# with no selector annotation rendered — the shape that actually shipped) and
# populated. The empty one is the dangerous one: `read -a` would drop it and
# the row would look well-formed.
run_rows "$FIXTURE_SELECTOR"
check "rows: 6-field row (populated last column) → 1 failure" 1 "$MT_REFLECTOR_FAILURES"
has "rows: 6-field row (populated) names the field count" "has 6 field(s), expected 5" "$out"
run_rows "$FIXTURE_HEALTHY"
check "rows: 6-field row → 1 failure" 1 "$MT_REFLECTOR_FAILURES"
check "rows: 6-field row → 0 checked" 0 "$MT_REFLECTOR_CHECKED"
has "rows: 6-field row names the field count" "has 6 field(s), expected 5" "$out"
lacks "rows: 6-field row is NOT reported as a selector finding" "namespaces-selector" "$out"
check "rows: 6-field row never waited" "" "$WAITED"

run_rows ""
check "rows: empty input → 0 checked" 0 "$MT_REFLECTOR_CHECKED"
check "rows: empty input → 0 failures" 0 "$MT_REFLECTOR_FAILURES"
STUB_WAIT_RC=1
run_rows "$(reset; listing "$FIXTURE_HEALTHY"; _list_sources)"
check "rows: a lagging mirror counts as a failure" 1 "$MT_REFLECTOR_FAILURES"
STUB_WAIT_RC=0

# --- _tenant_source ----------------------------------------------------------
tsecret() { echo "$3" > "$MT_TEST_STATE/$1.$2.rv"; echo "${4:-}" > "$MT_TEST_STATE/$1.$2.auto"; echo "${5:-}" > "$MT_TEST_STATE/$1.$2.allowed"; echo "${6:-}" > "$MT_TEST_STATE/$1.$2.sel"; }
reset; tsecret tn-x-matrix wildcard-tls-x 100 "tn-x-mail,infra-auth" "tn-x-mail,infra-auth" ""
row=$(_tenant_source x); rc=$?
check "_tenant_source: rc" 0 "$rc"
check "_tenant_source: 5 fields" 5 "$(printf '%s\n' "$row" | awk -F'\t' '{print NF}')"
check "_tenant_source: same layout as _list_sources" "tn-x-matrix wildcard-tls-x tn-x-mail,infra-auth tn-x-mail,infra-auth $_MT_REFLECTOR_EMPTY" "$(printf '%s\n' "$row" | awk -F'\t' '{print $1, $2, $3, $4, $5}')"
run_rows "$row"
check "_tenant_source: its row passes the consumer" 0 "$MT_REFLECTOR_FAILURES"
lacks "_tenant_source: no false selector finding" "namespaces-selector" "$out"
reset
_tenant_source x >/dev/null 2>&1; check "_tenant_source: absent Secret → rc 1" 1 "$?"
reset; touch "$MT_TEST_STATE/tn-x-matrix.wildcard-tls-x.unreadable"
_tenant_source x >/dev/null 2>&1; check "_tenant_source: unreadable Secret → rc 2" 2 "$?"
# Deleted between the resourceVersion read and the annotation reads: the
# MISSING token must not travel on as a namespace list or a selector.
reset; tsecret tn-x-matrix wildcard-tls-x 100 "tn-x-mail" "tn-x-mail" ""
cat > "$TMP/bin/kubectl" <<'FAKE2'
#!/usr/bin/env bash
set -u
printf '%s\n' "kubectl $*" >> "$MT_TEST_CALLS"
name=$3; ns=$5
case " $* " in *" --ignore-not-found -o name "*) exit 0 ;; esac
path=${7#jsonpath=}
case "$path" in
    *resourceVersion*) cat "$MT_TEST_STATE/$ns.$name.rv" ;;
    *) echo "Error from server (NotFound): secrets \"$name\" not found" >&2; exit 1 ;;
esac
FAKE2
chmod +x "$TMP/bin/kubectl"
row=$(_tenant_source x 2>/dev/null); rc=$?
check "_tenant_source: Secret vanishes mid-read → rc 1" 1 "$rc"
check "_tenant_source: ...and emits no row" "" "$row"
lacks "_tenant_source: the MISSING token never becomes a field" "MISSING" "$row"

echo "test-verify-reflector.sh: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
