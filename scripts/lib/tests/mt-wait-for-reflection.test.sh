#!/usr/bin/env bash
# Unit tests for the reflector propagation gates in scripts/lib/common.sh
# (issue #673): mt_wait_for_reflection and mt_reflector_canary. Runs against an
# inline fake kubectl — no cluster needed. Invoked by
# ci/scripts/shell-unit-tests.sh.
#
# The fake models Secrets as files under $MT_TEST_STATE:
#   <ns>.<name>.rv          the object's metadata.resourceVersion (absent = NotFound)
#   <ns>.<name>.reflected   its reflected-version annotation (absent = unannotated)
#   <ns>.<name>.stamp       its data.stamp (base64, as the API would return it)
#   <ns>.<name>.unreadable  any read fails with a non-NotFound error
#   flip-at / flip-ns       after N `get secret` calls, copy <flip-ns>.*.reflected.later
#                           over .reflected (a controller catching up mid-wait)
# and refuses whole-object reads (-o json/yaml) of a Secret: the gates must
# only ever pull metadata fields, so Secret data can never leak into a log.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "$HERE/../common.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export MT_TEST_CALLS="$TMP/calls" MT_TEST_STATE="$TMP/state" MT_TEST_MANIFEST="$TMP/manifest" MT_TEST_SCENARIO=""
export MT_REFLECTION_POLL_INTERVAL=0
cat > "$TMP/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -u
printf '%s\n' "kubectl $*" >> "$MT_TEST_CALLS"
S="$MT_TEST_STATE"
bump() { local f="$S/count.$1" n; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$f"; echo "$n"; }
case " $* " in
    *" -o json "*|*" -o yaml "*|*" -ojson "*|*" -oyaml "*|*" -o=json "*|*" -o=yaml "*)
        # (trailing space: "-o jsonpath=..." is a metadata read and allowed)
        echo "fake-kubectl: whole-object read of a Secret is forbidden in the reflector gates: $*" >&2; exit 98 ;;
    *" get secret "*)
        # kubectl get secret NAME -n NS -o jsonpath=PATH
        name=$3; ns=$5; path=${7#jsonpath=}
        n=$(bump getsecret)
        if [ -f "$S/flip-at" ] && [ "$n" -ge "$(cat "$S/flip-at")" ]; then
            fns=$(cat "$S/flip-ns")
            for later in "$S/$fns".*.reflected.later; do
                [ -e "$later" ] && mv "$later" "${later%.later}"
            done
        fi
        [ -f "$S/$ns.$name.unreadable" ] && { echo "Unable to connect to the server: dial tcp: i/o timeout" >&2; exit 1; }
        [ -f "$S/$ns.$name.rv" ] || { echo "Error from server (NotFound): secrets \"$name\" not found" >&2; exit 1; }
        case "$path" in
            '{.metadata.resourceVersion}') cat "$S/$ns.$name.rv" ;;
            '{.metadata.annotations.reflector\.v1\.k8s\.emberstack\.com/reflected-version}') cat "$S/$ns.$name.reflected" 2>/dev/null ;;
            '{.data.stamp}') cat "$S/$ns.$name.stamp" 2>/dev/null ;;
            *) echo "fake-kubectl: unscripted jsonpath $path" >&2; exit 99 ;;
        esac
        exit 0 ;;
    *" diff -f - "*)
        cat > /dev/null; echo "+  stamp: LEAK-CANARY"; exit 1 ;;
    *" apply -f - "*)
        cat > "$MT_TEST_MANIFEST"
        [ "$MT_TEST_SCENARIO" = "canary-apply-fail" ] && { echo "error: dial tcp 10.0.0.1:443: connection refused" >&2; exit 1; }
        src=$(awk '$1 == "namespace:" { print $2; exit }' "$MT_TEST_MANIFEST")
        tgt=$(awk -F'"' '/reflection-auto-namespaces:/ { print $2; exit }' "$MT_TEST_MANIFEST")
        stamp=$(awk '$1 == "stamp:" { print $2; exit }' "$MT_TEST_MANIFEST")
        old=$(cat "$S/$src.reflector-canary.rv" 2>/dev/null || echo 500); new=$((old + 1))
        echo "$new" > "$S/$src.reflector-canary.rv"; echo "$stamp" > "$S/$src.reflector-canary.stamp"
        case "$MT_TEST_SCENARIO" in
            canary-ok)              echo 1 > "$S/$tgt.reflector-canary.rv"; echo "$new" > "$S/$tgt.reflector-canary.reflected"; echo "$stamp" > "$S/$tgt.reflector-canary.stamp" ;;
            canary-stamp-mismatch)  echo 1 > "$S/$tgt.reflector-canary.rv"; echo "$new" > "$S/$tgt.reflector-canary.reflected"; echo "b2xk" > "$S/$tgt.reflector-canary.stamp" ;;
            canary-dead)            ;;   # controller never touches the target
        esac
        echo "secret/reflector-canary configured"; exit 0 ;;
esac
echo "fake-kubectl: unscripted call: $*" >&2; exit 99
FAKE
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH"

PASS=0; FAIL=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: expected [$2] got [$3]"; fi
}
has() {  # has <description> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" yes yes ;; *) check "$1" "contains [$2]" "$(printf '%s' "$3" | tr '\n' '|')" ;; esac
}
lacks() {  # lacks <description> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "no [$2]" "$(printf '%s' "$3" | tr '\n' '|')" ;; *) check "$1" yes yes ;; esac
}
reset() { rm -rf "$MT_TEST_STATE" "$MT_TEST_MANIFEST"; mkdir -p "$MT_TEST_STATE"; : > "$MT_TEST_CALLS"; export MT_TEST_SCENARIO="${1:-}"; mt_reset_change_tracker; }
secret() {  # secret <ns> <name> <rv> [reflected] [stamp]
    echo "$3" > "$MT_TEST_STATE/$1.$2.rv"
    [ -n "${4:-}" ] && echo "$4" > "$MT_TEST_STATE/$1.$2.reflected"
    [ -n "${5:-}" ] && echo "$5" > "$MT_TEST_STATE/$1.$2.stamp"
    return 0
}
SRC=tn-x-matrix; SEC=wildcard-tls-x; TARGETS="tn-x-mail,tn-x-docs,infra-auth"

# --- every mirror in sync: passes ---------------------------------------------
reset
secret $SRC $SEC 100; secret tn-x-mail $SEC 7 100; secret tn-x-docs $SEC 8 100; secret infra-auth $SEC 9 100
out=$(mt_wait_for_reflection $SRC $SEC "$TARGETS" 0 2>&1); rc=$?
check "in-sync: rc" 0 "$rc"
has "in-sync: says so" "in sync in 3 namespace(s)" "$out"
has "in-sync: names the source rv" "(rv 100)" "$out"
check "in-sync: no whole-object reads" 0 "$(grep -cE ' -o=?(json|yaml)( |$)' "$MT_TEST_CALLS")"
has "in-sync: reads only metadata fields" "-o jsonpath={.metadata." "$(cat "$MT_TEST_CALLS")"

# --- one lagging namespace: fails and the message names exactly it ----------
reset
secret $SRC $SEC 100; secret tn-x-mail $SEC 7 100; secret tn-x-docs $SEC 8 99; secret infra-auth $SEC 9 100
out=$(mt_wait_for_reflection $SRC $SEC "$TARGETS" 0 2>&1); rc=$?
check "lagging: rc" 1 "$rc"
has "lagging: names the namespace with its stale rv" "tn-x-docs:99" "$out"
has "lagging: names the source rv" "(src rv=100)" "$out"
lacks "lagging: in-sync namespaces not blamed" "tn-x-mail:" "$out"
lacks "lagging: in-sync namespaces not blamed (2)" "infra-auth:" "$out"
has "lagging: names the fix" "logs deploy/reflector" "$out"
has "lagging: is an [ERROR]" "[ERROR]" "$out"

# --- a MISSING mirror: fails, named as MISSING -------------------------------
reset
secret $SRC $SEC 100; secret tn-x-mail $SEC 7 100; secret infra-auth $SEC 9 100
out=$(mt_wait_for_reflection $SRC $SEC "$TARGETS" 0 2>&1); rc=$?
check "missing: rc" 1 "$rc"
has "missing: named" "tn-x-docs:MISSING" "$out"

# --- a mirror that exists but was never written by the controller -----------
reset
secret $SRC $SEC 100; secret tn-x-mail $SEC 7 100; secret tn-x-docs $SEC 8; secret infra-auth $SEC 9 100
out=$(mt_wait_for_reflection $SRC $SEC "$TARGETS" 0 2>&1); rc=$?
check "unannotated: rc" 1 "$rc"
has "unannotated: named" "tn-x-docs:UNANNOTATED" "$out"

# --- an unreadable mirror is not "in sync" -----------------------------------
reset
secret $SRC $SEC 100; secret tn-x-mail $SEC 7 100; secret tn-x-docs $SEC 8 100; secret infra-auth $SEC 9 100
touch "$MT_TEST_STATE/infra-auth.$SEC.unreadable"
out=$(mt_wait_for_reflection $SRC $SEC "$TARGETS" 0 2>&1); rc=$?
check "unreadable: rc" 1 "$rc"
has "unreadable: named" "infra-auth:UNREADABLE" "$out"

# --- source missing: fails and points at issuance, not the controller -------
reset
secret tn-x-mail $SEC 7 100
out=$(mt_wait_for_reflection $SRC $SEC "tn-x-mail" 0 2>&1); rc=$?
check "source missing: rc" 1 "$rc"
has "source missing: named" "source:MISSING" "$out"
has "source missing: points at issuance" "issuance problem" "$out"
lacks "source missing: does not blame the reflector" "reflector is not propagating" "$out"

# --- controller catching up mid-wait: passes ---------------------------------
reset
secret $SRC $SEC 100; secret tn-x-mail $SEC 7 99; secret tn-x-docs $SEC 8 100
echo 100 > "$MT_TEST_STATE/tn-x-mail.$SEC.reflected.later"; echo 4 > "$MT_TEST_STATE/flip-at"; echo tn-x-mail > "$MT_TEST_STATE/flip-ns"
out=$(MT_REFLECTION_POLL_INTERVAL=0.2 mt_wait_for_reflection $SRC $SEC "tn-x-mail, tn-x-docs" 5 2>&1); rc=$?
check "catch-up: rc" 0 "$rc"
has "catch-up: waited at least once" "Waiting for reflection" "$out"
has "catch-up: spaces in the list are trimmed" "tn-x-mail tn-x-docs" "$out"

# --- source renewed mid-wait: the new rv is what must be reached ------------
reset
secret $SRC $SEC 101; secret tn-x-mail $SEC 7 100
out=$(mt_wait_for_reflection $SRC $SEC "tn-x-mail" 0 2>&1); rc=$?
check "renewed source: stale mirror fails against the NEW rv" 1 "$rc"
has "renewed source: shows both" "tn-x-mail:100 (src rv=101)" "$out"

# --- empty target list is a failure, not a vacuous pass ----------------------
reset
secret $SRC $SEC 100
out=$(mt_wait_for_reflection $SRC $SEC " , " 0 2>&1); rc=$?
check "empty targets: rc" 1 "$rc"
has "empty targets: explains" "empty target namespace list" "$out"

# --- canary: healthy controller ----------------------------------------------
reset canary-ok
out=$(mt_reflector_canary infra-cert-manager infra-auth 0 2>&1); rc=$?
check "canary ok: rc" 0 "$rc"
has "canary ok: greppable success line" "reflector-canary reflected-version matches" "$out"
lacks "canary ok: diff stdout never printed" "LEAK-CANARY" "$out"
m=$(cat "$MT_TEST_MANIFEST")
has "canary manifest: name" "name: reflector-canary" "$m"
has "canary manifest: namespace" "namespace: infra-cert-manager" "$m"
has "canary manifest: allowed" 'reflection-allowed: "true"' "$m"
has "canary manifest: allowed-namespaces" 'reflection-allowed-namespaces: "infra-auth"' "$m"
has "canary manifest: auto-enabled" 'reflection-auto-enabled: "true"' "$m"
has "canary manifest: auto-namespaces" 'reflection-auto-namespaces: "infra-auth"' "$m"
lacks "canary manifest: no selector annotation" "namespaces-selector" "$m"
has "canary manifest: Opaque" "type: Opaque" "$m"
stamp_b64=$(awk '$1 == "stamp:" { print $2 }' "$MT_TEST_MANIFEST")
stamp=$(printf '%s' "$stamp_b64" | base64 -d 2>/dev/null)
case "$stamp" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) check "canary manifest: stamp is base64 epoch seconds" y y ;; *) check "canary manifest: stamp is base64 epoch seconds" "epoch" "$stamp" ;; esac
has "canary ok: stamp echoed from our own value, not the Secret" "stamp $stamp mirrored" "$out"
check "canary ok: change tracker restored (was clean)" false "$_mt_deploy_changed"
has "canary ok: diff ran before apply" "kubectl diff -f -" "$(cat "$MT_TEST_CALLS")"

# --- canary: a prior change flag survives the canary -------------------------
reset canary-ok
_mt_deploy_changed=true
mt_reflector_canary infra-cert-manager infra-auth 0 >/dev/null 2>&1; rc=$?
check "canary keeps prior flag: rc" 0 "$rc"
check "canary keeps prior flag: still true" true "$_mt_deploy_changed"

# --- canary: dead controller, mirror never updated ---------------------------
reset canary-dead
secret infra-auth reflector-canary 1 450 b2xk
out=$(mt_reflector_canary infra-cert-manager infra-auth 0 2>&1); rc=$?
check "canary dead: rc" 1 "$rc"
has "canary dead: names the target with its stale rv" "infra-auth:450" "$out"
has "canary dead: names the fix" "logs deploy/reflector" "$out"
check "canary dead: change tracker restored" false "$_mt_deploy_changed"

# --- canary: dead controller, no mirror at all (cold start) ------------------
reset canary-dead
out=$(mt_reflector_canary infra-cert-manager infra-auth 0 2>&1); rc=$?
check "canary dead/no mirror: rc" 1 "$rc"
has "canary dead/no mirror: MISSING named" "infra-auth:MISSING" "$out"

# --- canary: annotation updated but data not carried -------------------------
reset canary-stamp-mismatch
out=$(mt_reflector_canary infra-cert-manager infra-auth 0 2>&1); rc=$?
check "canary stamp mismatch: rc" 1 "$rc"
has "canary stamp mismatch: explains" "not stamp" "$out"
lacks "canary stamp mismatch: never prints the mirror's data" "b2xk" "$out"

# --- canary: apply itself fails → no wait, clear error -----------------------
reset canary-apply-fail
out=$(mt_reflector_canary infra-cert-manager infra-auth 0 2>&1); rc=$?
check "canary apply fail: rc" 1 "$rc"
has "canary apply fail: explains" "could not apply" "$out"
check "canary apply fail: no secret reads attempted" 0 "$(grep -c ' get secret ' "$MT_TEST_CALLS")"
check "canary apply fail: tracker restored" false "$_mt_deploy_changed"

echo "mt-wait-for-reflection: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
