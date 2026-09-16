#!/usr/bin/env bash
# Unit tests for scripts/verify-reflector's source discovery and row consumer.
# Driven by a fake kubectl — no cluster. The script guards `main` behind a
# BASH_SOURCE check so it can be sourced here.
#
# Three bug classes are pinned here, all of them false NEGATIVES or a false
# positive on the all-tenants path (the one check-health uses without -t):
#
#  1. Producer/consumer column drift. The listing rendered SIX columns (it also
#     selects reflection-auto-enabled, to filter on) while the consumer read
#     FIVE, so every healthy source was reported as carrying a selector
#     annotation. `read -a` with IFS=tab also DROPS empty and trailing fields,
#     so a naive count check could not catch it either.
#  2. Structural injection. Annotation values may contain tabs and NEWLINES,
#     which kubectl -o jsonpath emits raw, so one Secret rendered as two awk
#     records: a crafted value left a healthy-looking record while the real
#     allowed-namespaces and selector spilled onto a dropped continuation line.
#     A record marker alone does not fix this — the forged record carries the
#     marker and the right field count. Only identities (namespace/name, which
#     the API server constrains to RFC 1123) may travel in a delimited row.
#  3. In-band sentinel collision. `-` meant "empty", so a selector annotation
#     whose value was literally `-` decoded to empty and skipped the check.
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

# --- fixtures, and their provenance -----------------------------------------
# These are the bytes real kubectl renders for _list_source_ids' jsonpath.
# Derived with no cluster (kubectl create secret --dry-run=client | kubectl
# annotate --local -f - -o jsonpath='<per-item path>'), using the annotation
# set the live dev wildcard Secrets carry. The API server rejects a tab or a
# newline in a namespace or a name (RFC 1123, verified against dev with
# --dry-run=server), which is why only these two values may travel in a row.
ID_HEALTHY="MTROW${T}tn-x-matrix${T}wildcard-tls-x${T}true"
ID_OTHER="MTROW${T}tn-y-matrix${T}wildcard-tls-y${T}true"
ID_NOT_AUTO="MTROW${T}tn-x-matrix${T}apex-tls-x${T}"
ID_CANARY="MTROW${T}infra-cert-manager${T}reflector-canary${T}true"
# A Secret whose reflection-auto-namespaces contains tabs + a newline renders
# exactly this identity record — the poison is simply not in it (verified).
ID_POISONED="MTROW${T}tn-x-matrix${T}wildcard-tls-x${T}true"
# ...while poison inside reflection-auto-enabled can forge an EXTRA record.
ID_FORGED="MTROW${T}infra-evil${T}forged${T}true"
# A continuation line from a newline in some other annotation: no marker.
ID_SPILL="SPILLED${T}junk${T}junk${T}true"

check "fixture: identity record has 4 fields" 4 "$(printf '%s\n' "$ID_HEALTHY" | awk -F'\t' '{print NF}')"
check "fixture: field 1 is the record marker" MTROW "$(printf '%s\n' "$ID_HEALTHY" | awk -F'\t' '{print $1}')"
check "fixture: a poisoned Secret still renders a clean identity" "$ID_HEALTHY" "$ID_POISONED"

# --- fake kubectl ------------------------------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -u
printf '%s\n' "kubectl $*" >> "$MT_TEST_CALLS"
case " $* " in
    *" get secrets -A "*) cat "$MT_TEST_LISTING"; exit 0 ;;
    *" get secret "*)
        name=$3; ns=$5
        # Real kubectl: --ignore-not-found -o name is rc 0 + empty for an absent
        # object (how _mt_secret_meta tells MISSING from UNREADABLE); a jsonpath
        # read of an absent object is a NotFound error.
        case " $* " in *" --ignore-not-found -o name "*)
            [ -f "$MT_TEST_STATE/$ns.$name.unreadable" ] && { echo "Unable to connect to the server" >&2; exit 1; }
            [ -f "$MT_TEST_STATE/$ns.$name.rv" ] && echo "secret/$name"
            exit 0 ;;
        esac
        [ -f "$MT_TEST_STATE/$ns.$name.unreadable" ] && { echo "Unable to connect to the server" >&2; exit 1; }
        [ -f "$MT_TEST_STATE/$ns.$name.rv" ] || { echo "Error from server (NotFound): secrets \"$name\" not found" >&2; exit 1; }
        path=${7#jsonpath=}
        case "$path" in
            *resourceVersion*)                    cat "$MT_TEST_STATE/$ns.$name.rv" 2>/dev/null ;;
            *-selector*)                          cat "$MT_TEST_STATE/$ns.$name.sel" 2>/dev/null ;;
            *reflection-auto-namespaces\}*)       cat "$MT_TEST_STATE/$ns.$name.auto" 2>/dev/null ;;
            *reflection-allowed-namespaces\}*)    cat "$MT_TEST_STATE/$ns.$name.allowed" 2>/dev/null ;;
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
# secret <ns> <name> <rv> [auto] [allowed] [selectors]
secret() { echo "$3" > "$MT_TEST_STATE/$1.$2.rv"; printf '%s' "${4:-}" > "$MT_TEST_STATE/$1.$2.auto"; printf '%s' "${5:-}" > "$MT_TEST_STATE/$1.$2.allowed"; printf '%s' "${6:-}" > "$MT_TEST_STATE/$1.$2.sel"; }

# --- _list_source_ids --------------------------------------------------------
reset; listing "$ID_HEALTHY" "$ID_NOT_AUTO" "$ID_OTHER"
ids=$(_list_source_ids); rc=$?
check "ids: rc" 0 "$rc"
check "ids: only auto-enabled Secrets, as <ns>TAB<name>" "tn-x-matrix${T}wildcard-tls-x tn-y-matrix${T}wildcard-tls-y" "$(printf '%s\n' "$ids" | tr '\n' ' ' | sed 's/ $//')"
check "ids: the marker is consumed, not emitted" 2 "$(printf '%s\n' "$ids" | awk -F'\t' '{print NF}' | sort -u)"
lacks "ids: non auto-enabled Secret dropped" "apex-tls-x" "$ids"
# A continuation line has no marker and must be ignored, not read as a record.
reset; listing "$ID_HEALTHY" "$ID_SPILL"
ids=$(_list_source_ids)
lacks "ids: an unmarked continuation line is ignored" "junk" "$ids"
check "ids: ...and the real record survives" "tn-x-matrix${T}wildcard-tls-x" "$ids"
# Any malformed record fails the WHOLE listing rather than being salvaged.
reset; listing "$ID_HEALTHY" "MTROW${T}tn-z-matrix${T}oops"
ids=$(_list_source_ids); rc=$?
check "ids: a short record fails the listing (fail closed)" 1 "$rc"
reset; listing "$ID_HEALTHY" "MTROW${T}a${T}b${T}true${T}extra"
_list_source_ids >/dev/null; check "ids: a long record fails the listing" 1 "$?"
# The listing jsonpath must satisfy the metadata-only allowlist (the {"MTROW"}
# literal is admitted there); if it did not, the gate would fail closed.
reset; listing "$ID_HEALTHY"; _list_source_ids >/dev/null
check "ids: the listing jsonpath passes the metadata-only allowlist" 0 "$?"

# --- _reflector_read_source: values reach variables, never a shared string ---
reset; secret tn-x-matrix wildcard-tls-x 100 "tn-x-mail,infra-auth" "tn-x-mail,infra-auth" ""
_reflector_read_source tn-x-matrix wildcard-tls-x; rc=$?
check "read: rc" 0 "$rc"
check "read: auto" "tn-x-mail,infra-auth" "$MT_SRC_AUTO"
check "read: allowed" "tn-x-mail,infra-auth" "$MT_SRC_ALLOWED"
check "read: selectors empty" "" "$MT_SRC_SELECTORS"
# A tab/newline in a value is just part of the value — nothing to shift.
reset; secret tn-x-matrix wildcard-tls-x 100 "$(printf 'a\tb\nc')" "tn-x-mail" "env=prod"
_reflector_read_source tn-x-matrix wildcard-tls-x
check "read: a value containing a tab and a newline survives intact" "$(printf 'a\tb\nc')" "$MT_SRC_AUTO"
check "read: ...and does not bleed into the next field" "tn-x-mail" "$MT_SRC_ALLOWED"
check "read: ...or the one after" "env=prod" "$MT_SRC_SELECTORS"
reset; _reflector_read_source tn-x-matrix wildcard-tls-x >/dev/null 2>&1; check "read: absent Secret → rc 1" 1 "$?"
reset; secret tn-x-matrix wildcard-tls-x 100; touch "$MT_TEST_STATE/tn-x-matrix.wildcard-tls-x.unreadable"
_reflector_read_source tn-x-matrix wildcard-tls-x >/dev/null 2>&1; check "read: unreadable Secret → rc 2" 2 "$?"

# --- _reflector_source_ok: plain values, nothing to decode ------------------
_reflector_source_ok tn-x-matrix wildcard-tls-x "tn-x-mail,infra-auth" "tn-x-mail,infra-auth" "" >/dev/null 2>&1
check "verdict: healthy source passes" 0 "$?"
out=$(_reflector_source_ok tn-y-matrix wildcard-tls-y "tn-y-mail" "tn-y-mail" "env=prod" 2>&1); rc=$?
check "verdict: selector flagged" 1 "$rc"; has "verdict: selector message" "namespaces-selector" "$out"
# The old in-band sentinel made a selector of exactly "-" decode to empty.
out=$(_reflector_source_ok tn-y-matrix wildcard-tls-y "tn-y-mail" "tn-y-mail" "-" 2>&1); rc=$?
check "verdict: a selector of exactly '-' is flagged (sentinel-collision bug)" 1 "$rc"
has "verdict: ...as a selector" "namespaces-selector" "$out"
out=$(_reflector_source_ok tn-a-matrix wildcard-tls-a "-" "-" "" 2>&1); rc=$?
check "verdict: namespace lists of exactly '-' are rejected" 1 "$rc"; has "verdict: ...as a bad entry" "lists '-'" "$out"
out=$(_reflector_source_ok tn-z-matrix wildcard-tls-z "" "tn-z-mail" "" 2>&1); rc=$?
check "verdict: empty auto list flagged" 1 "$rc"; has "verdict: empty auto message" "empty reflection-auto-namespaces" "$out"
out=$(_reflector_source_ok tn-w-matrix wildcard-tls-w "tn-w-mail" "" "" 2>&1); rc=$?
check "verdict: empty allowed list flagged" 1 "$rc"; has "verdict: empty allowed message" "empty reflection-allowed-namespaces" "$out"
out=$(_reflector_source_ok tn-b-matrix wildcard-tls-b "tn-b-mail,tn-b-docs" "tn-b-mail" "" 2>&1); rc=$?
check "verdict: auto != allowed flagged" 1 "$rc"; has "verdict: mismatch names both" "differs from reflection-allowed-namespaces" "$out"
out=$(_reflector_source_ok "" wildcard-tls-c "tn-c-mail" "tn-c-mail" "" 2>&1); rc=$?
check "verdict: empty namespace is an internal error" 1 "$rc"; has "verdict: ...says so" "no namespace/name" "$out"

# --- _bad_namespace_entry: DNS-1123 labels ----------------------------------
for bad in - --- -tn-x tn-x- .tn-x 'tn-x*' 'tn.x' TN-X; do
    check "dns1123: '$bad' rejected" "$bad" "$(_bad_namespace_entry "$bad")"
done
for good in tn-x-mail infra-auth a a1 1a tn-x-mail,infra-auth; do
    _bad_namespace_entry "$good" >/dev/null; check "dns1123: '$good' accepted" 1 "$?"
done
check "dns1123: the bad entry among good ones is the one reported" "-" "$(_bad_namespace_entry "tn-x-mail,-,infra-auth")"

# --- _reflector_check_ids: the one driver for both paths --------------------
WAITED=""
mt_wait_for_reflection() { WAITED="${WAITED}${WAITED:+ }$1/$2->$3"; [ "${STUB_WAIT_RC:-0}" -eq 0 ]; }
# Reports through globals, so it must NOT run in a command substitution — a
# subshell would swallow the counters (as piping into mt_apply does, #644).
run_ids() { WAITED=""; _reflector_check_ids 0 <<< "$1" > "$TMP/ids.out" 2>&1; out=$(cat "$TMP/ids.out"); }

reset; secret tn-x-matrix wildcard-tls-x 100 "tn-x-mail,infra-auth" "tn-x-mail,infra-auth" ""
run_ids "tn-x-matrix${T}wildcard-tls-x"
check "driver: healthy source → 0 failures" 0 "$MT_REFLECTOR_FAILURES"
check "driver: healthy source → 1 checked" 1 "$MT_REFLECTOR_CHECKED"
check "driver: waited on the real target list" "tn-x-matrix/wildcard-tls-x->tn-x-mail,infra-auth" "$WAITED"
lacks "driver: no false selector finding" "namespaces-selector" "$out"
reset; secret tn-x-matrix wildcard-tls-x 100 "tn-x-mail" "tn-x-mail" ""
secret tn-y-matrix wildcard-tls-y 100 "tn-y-mail" "tn-y-mail" "env=prod"
run_ids "$(printf 'tn-x-matrix\twildcard-tls-x\ntn-y-matrix\twildcard-tls-y')"
check "driver: mixed → 1 failure" 1 "$MT_REFLECTOR_FAILURES"
check "driver: mixed → 2 checked" 2 "$MT_REFLECTOR_CHECKED"
check "driver: only the healthy source was waited on" "tn-x-matrix/wildcard-tls-x->tn-x-mail" "$WAITED"
has "driver: the selector source is the one flagged" "tn-y-matrix/wildcard-tls-y carries" "$out"
reset
run_ids "infra-evil${T}forged"
check "driver: a forged/absent identity → 1 failure" 1 "$MT_REFLECTOR_FAILURES"
has "driver: ...reported distinguishably from a lagging mirror" "no longer exists" "$out"
lacks "driver: ...not as a selector finding" "namespaces-selector" "$out"
check "driver: ...and never waited" "" "$WAITED"
run_ids "a${T}b${T}c"
check "driver: a 3-field identity line → 1 failure" 1 "$MT_REFLECTOR_FAILURES"
has "driver: ...named as a malformed identity" "is not a <namespace> TAB <name> identity" "$out"
run_ids ""
check "driver: empty input → 0 checked" 0 "$MT_REFLECTOR_CHECKED"
check "driver: empty input → 0 failures" 0 "$MT_REFLECTOR_FAILURES"
reset; secret tn-x-matrix wildcard-tls-x 100 "tn-x-mail" "tn-x-mail" ""
STUB_WAIT_RC=1; run_ids "tn-x-matrix${T}wildcard-tls-x"
check "driver: a lagging mirror counts as a failure" 1 "$MT_REFLECTOR_FAILURES"
STUB_WAIT_RC=0

# --- END TO END: the injection must not read as healthy ---------------------
# The Secret really carries a forbidden allowed-namespaces AND a selector; its
# reflection-auto-namespaces contains tabs and a newline to hide them. The old
# all-tenants path reported checked=1 failures=0 for exactly this.
reset
listing "$ID_POISONED"
secret tn-x-matrix wildcard-tls-x 100 "$(printf 'tn-x-mail\tvtn-x-mail\te\nSPILLED')" "EVERY-NAMESPACE-I-WANT" "env=prod"
ids=$(_list_source_ids); rc=$?
check "injection: the listing still succeeds" 0 "$rc"
check "injection: ...yielding the true identity" "tn-x-matrix${T}wildcard-tls-x" "$ids"
run_ids "$ids"
check "injection: NOT reported as healthy" 1 "$MT_REFLECTOR_FAILURES"
check "injection: the source WAS examined" 1 "$MT_REFLECTOR_CHECKED"
has "injection: the hidden selector is what is flagged" "tn-x-matrix/wildcard-tls-x carries a *-namespaces-selector" "$out"
check "injection: never waited on a forged target list" "" "$WAITED"
lacks "injection: not dismissed as an internal parse error" "internal:" "$out"
# ...and with the selector removed, the hidden allowed-namespaces is caught.
reset; listing "$ID_POISONED"
secret tn-x-matrix wildcard-tls-x 100 "$(printf 'tn-x-mail\tvtn-x-mail\te\nSPILLED')" "EVERY-NAMESPACE-I-WANT" ""
run_ids "$(_list_source_ids)"
check "injection: without a selector, still NOT healthy" 1 "$MT_REFLECTOR_FAILURES"
has "injection: the forbidden allowed-namespaces is flagged" "EVERY-NAMESPACE-I-WANT" "$out"

echo "test-verify-reflector.sh: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
