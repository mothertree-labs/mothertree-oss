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
# ...used below to prove a forged identity is reported, not silently skipped.
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
            *reflection-auto-enabled\}*)          cat "$MT_TEST_STATE/$ns.$name.enabled" 2>/dev/null ;;
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
run_ids "$(printf '%s\n' "$ID_FORGED" | awk -F'\t' '{print $2 "\t" $3}')"
check "driver: a forged/absent identity → 1 failure" 1 "$MT_REFLECTOR_FAILURES"
has "driver: ...reported distinguishably from a lagging mirror" "deleted or turned unreadable since" "$out"
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
has "injection: the poisoned list itself is flagged as a bad entry" "reflection-auto-namespaces lists" "$out"
lacks "injection: not dismissed as an internal parse error" "internal:" "$out"
# ...and a Secret whose lists are clean but whose allowed list is forbidden is
# still caught on the allowed list.
reset; listing "$ID_POISONED"
secret tn-x-matrix wildcard-tls-x 100 "tn-x-mail" "EVERY-NAMESPACE-I-WANT" ""
run_ids "$(_list_source_ids)"
check "a forbidden allowed-namespaces is a finding" 1 "$MT_REFLECTOR_FAILURES"
has "...named on the allowed list" "EVERY-NAMESPACE-I-WANT" "$out"

# --- the auto-enabled predicate: as permissive as the controller ------------
# Upstream trims and parses a boolean, so these all auto-reflect and must be
# checked; requiring the exact string "true" left them silently unchecked.
for v in true True TRUE tRuE " true" "true " "  true  "; do
    reset; listing "MTROW${T}tn-x-matrix${T}wildcard-tls-x${T}${v}"
    check "auto-enabled [$v] is selected" "tn-x-matrix${T}wildcard-tls-x" "$(_list_source_ids)"
    _reflector_is_auto_enabled "$v"; check "auto-enabled [$v] parses true in bash too" 0 "$?"
done
# Unambiguously not enabled: absent or false. These stay silent — the empty
# case is nearly every Secret in the cluster.
for v in "" "  " false False FALSE; do
    reset; listing "MTROW${T}tn-x-matrix${T}wildcard-tls-x${T}${v}"
    check "auto-enabled [$v] is silently not selected" "" "$(_list_source_ids)"
    _reflector_is_auto_enabled "$v"; check "auto-enabled [$v] reads as not-enabled" 1 "$?"
done
# Neither true nor false: NOT silently dropped — surfaced as AMBIGUOUS.
for v in yes 1 "true false" truthy "tru e"; do
    reset; listing "MTROW${T}tn-x-matrix${T}wildcard-tls-x${T}${v}"
    check "auto-enabled [$v] is surfaced as AMBIGUOUS" "AMBIGUOUS${T}tn-x-matrix${T}wildcard-tls-x" "$(_list_source_ids)"
    _reflector_is_auto_enabled "$v"; check "auto-enabled [$v] reads as ambiguous" 2 "$?"
done
# ...and the driver counts it as unevaluable, names it, and checks nothing.
reset; listing "MTROW${T}tn-x-matrix${T}wildcard-tls-x${T}yes"
run_ids "$(_list_source_ids)"
check "ambiguous: nothing checked" 0 "$MT_REFLECTOR_CHECKED"
check "ambiguous: no finding" 0 "$MT_REFLECTOR_FAILURES"
check "ambiguous: counted unevaluable" 1 "$MT_REFLECTOR_UNEVALUABLE"
has "ambiguous: names the Secret" "tn-x-matrix/wildcard-tls-x" "$out"
has "ambiguous: says why" "neither true nor false" "$out"
check "ambiguous: never waited" "" "$WAITED"
# The -t path reaches the same verdict through its own pre-check.
export MT_ENV=test
reset; secret tn-x-matrix wildcard-tls-x 100 "tn-x-mail" "tn-x-mail" ""
echo yes > "$MT_TEST_STATE/tn-x-matrix.wildcard-tls-x.enabled"
out=$(_reflector_tenant_id x 2>&1 >/dev/null); rc=$?
check "-t: an ambiguous auto-enabled → rc 2 (cannot evaluate)" 2 "$rc"
has "-t: ...and says why" "neither true nor false" "$out"

# --- a malformed record fails closed AND names where to look (item 3) -------
reset; listing "$ID_HEALTHY" "$ID_OTHER" "MTROW${T}tn-z-matrix${T}oops"
err=$(_list_source_ids 2>&1 >/dev/null); rc=$?
check "malformed: listing fails closed" 1 "$rc"
has "malformed: names the line" "at line 3" "$err"
has "malformed: names the Secret it follows" "tn-y-matrix/wildcard-tls-y" "$err"

# --- canary identity: namespace AND name (item 1) ---------------------------
# A tenant Secret that happens to be called reflector-canary must NOT be
# dropped — dropping it would leave it silently unchecked.
IDS_WITH_IMPOSTOR="$(printf 'infra-cert-manager\treflector-canary\ntn-x-matrix\treflector-canary\ntn-x-matrix\twildcard-tls-x')"
printf '%s\n' "$IDS_WITH_IMPOSTOR" | _has_canary_id; check "canary: positive control finds the real canary" 0 "$?"
check "canary: only the real canary is stripped" "tn-x-matrix${T}reflector-canary tn-x-matrix${T}wildcard-tls-x" "$(printf '%s\n' "$IDS_WITH_IMPOSTOR" | _strip_canary_id | tr '\n' ' ' | sed 's/ $//')"
printf '%s\n' "tn-x-matrix${T}reflector-canary" | _has_canary_id; check "canary: an impostor does not satisfy the positive control" 1 "$?"
check "canary: the real canary identity is recognised from the listing" "infra-cert-manager${T}reflector-canary" "$(reset; listing "$ID_CANARY"; _list_source_ids)"

# --- the -t pre-check (item 6) ----------------------------------------------
export MT_ENV=test
reset; secret tn-x-matrix wildcard-tls-x 100 "tn-x-mail" "tn-x-mail" ""
echo true > "$MT_TEST_STATE/tn-x-matrix.wildcard-tls-x.enabled"
check "-t: healthy tenant yields its identity" "tn-x-matrix${T}wildcard-tls-x" "$(_reflector_tenant_id x 2>/dev/null)"
reset
out=$(_reflector_tenant_id x 2>&1 >/dev/null); rc=$?
check "-t: absent Secret → rc 1" 1 "$rc"; has "-t: ...with the create_env wording" "has create_env run" "$out"
lacks "-t: ...and never blames a listing it did not run" "listed as auto-reflected" "$out"
reset; secret tn-x-matrix wildcard-tls-x 100 "tn-x-mail" "tn-x-mail" ""
touch "$MT_TEST_STATE/tn-x-matrix.wildcard-tls-x.unreadable"
_reflector_tenant_id x >/dev/null 2>&1; check "-t: unreadable Secret → rc 2" 2 "$?"
reset; secret tn-x-matrix wildcard-tls-x 100 "tn-x-mail" "tn-x-mail" ""
echo false > "$MT_TEST_STATE/tn-x-matrix.wildcard-tls-x.enabled"
out=$(_reflector_tenant_id x 2>&1 >/dev/null); rc=$?
check "-t: reflection disabled → rc 1" 1 "$rc"
has "-t: ...says reflection is not enabled" "reflection-auto-enabled is not true" "$out"
lacks "-t: ...and does not blame the controller" "not propagating" "$out"

# --- an unreadable source is "cannot evaluate", not a finding (item 4) ------
reset; secret tn-x-matrix wildcard-tls-x 100 "tn-x-mail" "tn-x-mail" ""
touch "$MT_TEST_STATE/tn-x-matrix.wildcard-tls-x.unreadable"
run_ids "tn-x-matrix${T}wildcard-tls-x"
check "unevaluable: counted apart from findings" 0 "$MT_REFLECTOR_FAILURES"
check "unevaluable: counted" 1 "$MT_REFLECTOR_UNEVALUABLE"
has "unevaluable: says it cannot judge" "cannot judge whether its mirrors are in sync" "$out"
reset
run_ids "infra-evil${T}forged"
check "deleted source is still a finding, not unevaluable" 1 "$MT_REFLECTOR_FAILURES"
check "...and not counted as unevaluable" 0 "$MT_REFLECTOR_UNEVALUABLE"
has "...with neutral wording (no listing is implied)" "deleted or turned unreadable since" "$out"

# --- internal whitespace is flagged, not repaired (item 8) ------------------
check "whitespace: an internal space is a bad entry" "tn-x mail" "$(_bad_namespace_entry 'tn-x mail')"
_bad_namespace_entry '  tn-x-mail  ,  infra-auth  ' >/dev/null
check "whitespace: ends are trimmed as the controller does" 1 "$?"

# --- log-spoofing defence (item 7) ------------------------------------------
EVIL_ENTRY="$(printf 'tn-x\033[2K\\e[32m[SUCCESS] all good')"
safe=$(_reflector_safe "$EVIL_ENTRY")
lacks "safe: raw escape byte removed" "$(printf '\033')" "$safe"
has "safe: backslash escaped so echo -e cannot expand it" '\\e' "$safe"
out=$(_reflector_source_ok tn-x-matrix wildcard-tls-x "$EVIL_ENTRY" "$EVIL_ENTRY" "" 2>&1)
# print_error is `echo -e` with colour codes, so the line legitimately holds
# escapes of its own; what must never survive is the INJECTED sequence.
lacks "safe: the injected erase-line sequence never reaches the log" "$(printf '\033[2K')" "$out"
lacks "safe: the injected colour sequence never reaches the log" "$(printf '\033[32m')" "$out"
has "safe: the offending entry is still named" "SUCCESS" "$out"

# --- the subshell guard ------------------------------------------------------
( _reflector_check_ids 0 </dev/null ) >/dev/null 2>&1
check "guard: the driver refuses to run in a subshell" 2 "$?"
( _reflector_read_source tn-x-matrix wildcard-tls-x ) >/dev/null 2>&1
check "guard: the reader refuses to run in a subshell" 2 "$?"

# --- log forgery: assert on BYTES, not appearance (M1) ----------------------
# A newline inside reflection-auto-enabled authors a complete second record
# (marker, NF==4, a "true" flag), so field 2/3 of a listing record — the
# identity — is attacker-controlled. print_* are `echo -e`, so a literal \e
# becomes a real escape: a forged identity could erase the genuine error line
# and print a green [SUCCESS] in its place.
# ESC is 033 in `od -c`. print_error emits colour escapes of its own, so the
# assertion is that the malicious run contains no MORE escapes than a benign
# one producing the same number of lines, plus the injected sequences by name.
count_esc() { od -c < "$1" | tr -s ' ' '\n' | grep -c '^033$' || true; }
FORGED_NS="$(printf 'x\033[2K\\e[32m[SUCCESS] Reflector check passed on prod\\e[0m')"

# bash path 1: a forged identity that resolves to nothing (driver :301)
reset
run_ids "benign-ns${T}benign-name"; cp "$TMP/ids.out" "$TMP/benign.out"
run_ids "${FORGED_NS}${T}wildcard-tls-x"; cp "$TMP/ids.out" "$TMP/forged.out"
check "forgery(bash, deleted-path): no extra ESC bytes vs a benign run" "$(count_esc "$TMP/benign.out")" "$(count_esc "$TMP/forged.out")"
lacks "forgery(bash): the erase-line sequence never reaches the log" "$(printf '\033[2K')" "$(cat "$TMP/forged.out")"
lacks "forgery(bash): the green SUCCESS sequence never reaches the log" "$(printf '\033[32m')" "$(cat "$TMP/forged.out")"
has "forgery(bash): the forged identity is still reported" "was selected as auto-reflected" "$(cat "$TMP/forged.out")"

# bash path 2: a forged identity whose read fails with an API error (driver :305)
reset; secret "$FORGED_NS" wildcard-tls-x 100 "tn-x-mail" "tn-x-mail" ""
touch "$MT_TEST_STATE/${FORGED_NS}.wildcard-tls-x.unreadable"
run_ids "${FORGED_NS}${T}wildcard-tls-x"; cp "$TMP/ids.out" "$TMP/forged2.out"
check "forgery(bash, unreadable-path): counted unevaluable" 1 "$MT_REFLECTOR_UNEVALUABLE"
check "forgery(bash, unreadable-path): no extra ESC bytes" "$(count_esc "$TMP/benign.out")" "$(count_esc "$TMP/forged2.out")"
lacks "forgery(bash, unreadable-path): erase-line sequence absent" "$(printf '\033[2K')" "$(cat "$TMP/forged2.out")"

# awk path: the malformed-record message interpolates the PRECEDING identity.
# awk printf writes raw — no colour codes — so here NO escape byte at all may
# survive, which is the strongest form of the assertion.
reset
listing "MTROW${T}${FORGED_NS}${T}wildcard-tls-x${T}true" "MTROW${T}tn-z-matrix${T}oops"
_list_source_ids 2>"$TMP/awk.err" >/dev/null; rc=$?
check "forgery(awk): the malformed record still fails the listing closed" 1 "$rc"
check "forgery(awk): NOT ONE escape byte survives to stderr" 0 "$(count_esc "$TMP/awk.err")"
lacks "forgery(awk): erase-line sequence absent" "$(printf '\033[2K')" "$(cat "$TMP/awk.err")"
has "forgery(awk): the offending position is still named" "malformed listing record at line 2" "$(cat "$TMP/awk.err")"
has "forgery(awk): the preceding Secret is still named, scrubbed" "wildcard-tls-x" "$(cat "$TMP/awk.err")"
# The scrubbing must not mangle an ordinary identity.
reset; listing "MTROW${T}tn-y-matrix${T}wildcard-tls-y${T}true" "MTROW${T}tn-z-matrix${T}oops"
_list_source_ids 2>"$TMP/awk2.err" >/dev/null
has "awk: a clean identity is printed verbatim" "immediately after tn-y-matrix/wildcard-tls-y" "$(cat "$TMP/awk2.err")"

# The ambiguous record carries attacker bytes too, and is scrubbed as well.
reset; listing "MTROW${T}${FORGED_NS}${T}wildcard-tls-x${T}yes"
run_ids "$(_list_source_ids)"; cp "$TMP/ids.out" "$TMP/amb.out"
check "forgery(ambiguous): counted unevaluable" 1 "$MT_REFLECTOR_UNEVALUABLE"
check "forgery(ambiguous): no extra ESC bytes" "$(count_esc "$TMP/benign.out")" "$(count_esc "$TMP/amb.out")"
lacks "forgery(ambiguous): erase-line sequence absent" "$(printf '\033[2K')" "$(cat "$TMP/amb.out")"

# --- HIGH: the SYMMETRIC multi-line list (the shape create_env renders) ------
# Both annotations carry the same value, so the equality check passes; the old
# `read -r -a` stopped at the first newline, so every entry after one was
# neither validated nor polled while the controller copied the key there.
MULTI="$(printf 'tn-x-mail,\ninfra-auth,kube-system')"
reset; secret tn-x-matrix wildcard-tls-x 100 "$MULTI" "$MULTI" ""
run_ids "tn-x-matrix${T}wildcard-tls-x"
check "symmetric multi-line: still passes validation (all three are valid names)" 0 "$MT_REFLECTOR_FAILURES"
check "symmetric multi-line: EVERY entry is polled, not just the first" "tn-x-matrix/wildcard-tls-x->${MULTI}" "$WAITED"
has "symmetric multi-line: the namespaces hidden after the newline are named" "infra-auth,kube-system" "$out"
# ...and an INVALID entry hidden after the newline is now caught.
BADMULTI="$(printf 'tn-x-mail,\nkube-*,infra-auth')"
reset; secret tn-x-matrix wildcard-tls-x 100 "$BADMULTI" "$BADMULTI" ""
run_ids "tn-x-matrix${T}wildcard-tls-x"
check "symmetric multi-line: a bad entry after the newline is a finding" 1 "$MT_REFLECTOR_FAILURES"
has "symmetric multi-line: the hidden bad entry is named" "lists 'kube-*'" "$out"
check "symmetric multi-line: nothing was polled" "" "$WAITED"
# ...including one smuggling an escape sequence, which validation now reaches.
ESCMULTI="$(printf 'tn-x-mail,\n\033[32mfake,infra-auth')"
reset; secret tn-x-matrix wildcard-tls-x 100 "$ESCMULTI" "$ESCMULTI" ""
run_ids "tn-x-matrix${T}wildcard-tls-x"; cp "$TMP/ids.out" "$TMP/escmulti.out"
check "symmetric multi-line: a smuggled ESC entry is a finding" 1 "$MT_REFLECTOR_FAILURES"
check "symmetric multi-line: and no extra ESC byte reaches the log" "$(count_esc "$TMP/benign.out")" "$(count_esc "$TMP/escmulti.out")"

# --- MEDIUM: the SUCCESS path scrubs, asserted on bytes ---------------------
# A value whose entries are all valid can still carry raw newlines and tabs —
# they sit at entry boundaries and are trimmed away, so validation accepts
# them while the raw value still reaches print_status at the "Checking" line.
# Unscrubbed, `echo -e` would break that line in two.
reset; secret tn-x-matrix wildcard-tls-x 100 "$MULTI" "$MULTI" ""
run_ids "tn-x-matrix${T}wildcard-tls-x"; cp "$TMP/ids.out" "$TMP/success.out"
check "success path: the whole run is ONE log line (no smuggled newline)" 1 "$(awk 'END{print NR}' "$TMP/success.out")"
has "success path: the list is rendered without its control bytes" "-> tn-x-mail,infra-auth,kube-system" "$(cat "$TMP/success.out")"
check "success path: not one raw newline inside the message" 1 "$(od -c < "$TMP/success.out" | tr -s ' ' '\n' | grep -c '^\\n$')"
TABMULTI="$(printf 'tn-x-mail,\tinfra-auth')"
reset; secret tn-x-matrix wildcard-tls-x 100 "$TABMULTI" "$TABMULTI" ""
run_ids "tn-x-matrix${T}wildcard-tls-x"; cp "$TMP/ids.out" "$TMP/tab.out"
check "success path: a smuggled TAB is stripped too" 0 "$(od -c < "$TMP/tab.out" | tr -s ' ' '\n' | grep -c '^\\t$')"
has "success path: ...and the list still reads correctly" "-> tn-x-mail,infra-auth" "$(cat "$TMP/tab.out")"

echo "test-verify-reflector.sh: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
