#!/usr/bin/env bash
# Unit tests for Check 6 of scripts/check-health (firing Prometheus alerts).
#
# This runs the real script end to end against a fake kubectl — no cluster —
# because the failure mode being guarded here lives in the seam between the
# embedded Python and the shell that parses its output, not in either half.
# The Python prints a line protocol (DETAIL:/INFO:/MISSING:/TOTAL:) and the
# shell picks TOTAL: out with sed; two ways to make Check 6 report "no alerts"
# while alerts were firing were found there:
#
#   1. Prometheus label VALUES are arbitrary UTF-8 (only label NAMES have a
#      restricted charset), so a newline in one injects an extra line into that
#      protocol — `severity: "critical\nTOTAL:0"` gave TOTAL two lines, the
#      shell's integer test failed with "integer expression expected", and
#      since that test is an `if` condition `set -e` did not stop it: the else
#      branch printed "OK - No actionable alerts firing".
#   2. Check 6 reads the alert API with mt_prom_http, which (unlike
#      mt_prom_query) does not validate that the body is a successful
#      Prometheus response, so any other 200 — an error body, a proxy's HTML —
#      yielded an empty alert list and the line "OK - No actionable alerts
#      firing". The only thing that then made the run fail at all was the
#      deadman-presence check noticing that nothing was firing, which reports
#      a broken alert path rather than an unreadable body. (ALERT_DEADMAN is
#      the documented override for that check, but it is read with `:-`, so an
#      empty value falls back to the default rather than switching it off; the
#      cases below therefore assert on the fail-open *line* and pin the
#      behaviour both with the override set and with it left alone, so the fix
#      cannot depend on the deadman check running.)
#
# Every alert body below is a fixture; namespaces are infra-* placeholders.
# Invoked by ci/scripts/shell-unit-tests.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# check-health derives REPO_ROOT from its own invocation path and, since #673,
# runs `$REPO_ROOT/scripts/verify-reflector --passive` as Check 7. That gate
# talks to the cluster on its own account and is covered by its own suite
# (scripts/tests/test-verify-reflector.sh, 181 assertions); teaching this fake
# kubectl the reflector wire format as well would duplicate it and make THIS
# suite break whenever that format changes.
#
# So: run the REAL check-health (a symlink, so BASH_SOURCE is still the file
# under test) through a temp REPO_ROOT whose scripts/lib is the real one and
# whose verify-reflector is a stub returning MT_TEST_REFLECTOR_RC. Default 0,
# which restores this suite's contract that the exit code reflects Check 6
# alone; a case below sets it to 1 to pin that Check 7 is counted when it fails.
mkdir -p "$TMP/repo/scripts"
ln -s "$REPO/scripts/lib"          "$TMP/repo/scripts/lib"
ln -s "$REPO/scripts/check-health" "$TMP/repo/scripts/check-health"
cat > "$TMP/repo/scripts/verify-reflector" <<'STUB'
#!/usr/bin/env bash
exit "${MT_TEST_REFLECTOR_RC:-0}"
STUB
chmod +x "$TMP/repo/scripts/verify-reflector"
SCRIPT="$TMP/repo/scripts/check-health"
export MT_TEST_CALLS="$TMP/calls" MT_TEST_STDOUT="$TMP/stdout" MT_TEST_RC="$TMP/rc"
export MT_TEST_NAMESPACES="infra-monitoring infra-cert-manager infra-db"
# Answers the five kinds of call Check 1-6 make. Everything but the alert API
# answers "nothing wrong", so the exit code reflects Check 6 alone.
cat > "$TMP/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "kubectl $*" >> "$MT_TEST_CALLS"
case " $* " in
    *" get --raw "*)
        cat "$MT_TEST_STDOUT"; exit "$(cat "$MT_TEST_RC")" ;;
    *" get namespaces "*)
        printf '%s' "$MT_TEST_NAMESPACES"; exit 0 ;;
    *" get pods "*|*" get deployments "*|*" get pvc "*|*" get certificates "*)
        exit 0 ;;
esac
echo "fake-kubectl: unscripted call: $*" >&2; exit 99
FAKE
chmod +x "$TMP/bin/kubectl"
touch "$TMP/kubeconfig"

PASS=0; FAIL=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: expected [$2] got [$3]"; fi
}
contains() {  # contains <description> <needle> <haystack>
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); echo "FAIL: $1: [$2] not in: $3" ;; esac
}
lacks() {  # lacks <description> <needle> <haystack>
    case "$3" in *"$2"*) FAIL=$((FAIL + 1)); echo "FAIL: $1: [$2] unexpectedly in: $3" ;; *) PASS=$((PASS + 1)) ;; esac
}

OUT=""; RC=0
# Everything check-health reads from the environment is stripped, so a CI shell
# that happens to export one cannot change what these cases exercise:
# MT_TENANT narrows the namespace filter and skips a whole cert loop, and
# MT_PROM_SERVICE / MT_PROM_PORT are now validated by mt_prom_http, so a stray
# value turns every alert case into "could not query the alert API".
CLEAN_ENV=(env -u REPO_ROOT -u MT_TENANT -u MT_PROM_SERVICE -u MT_PROM_PORT)

# run <alerts-body> [ALERT_DEADMAN override] -> sets OUT and RC
run() {
    : > "$MT_TEST_CALLS"; printf '%s' "$1" > "$MT_TEST_STDOUT"; echo 0 > "$MT_TEST_RC"
    local deadman_set=0 deadman=""
    if [ "$#" -ge 2 ]; then deadman_set=1; deadman="$2"; fi
    if [ "$deadman_set" = 1 ]; then
        OUT=$("${CLEAN_ENV[@]}" PATH="$TMP/bin:$PATH" KUBECONFIG="$TMP/kubeconfig" \
                  ALERT_DEADMAN="$deadman" bash "$SCRIPT" -e test 2>&1); RC=$?
    else
        OUT=$("${CLEAN_ENV[@]}" -u ALERT_DEADMAN PATH="$TMP/bin:$PATH" KUBECONFIG="$TMP/kubeconfig" \
                  bash "$SCRIPT" -e test 2>&1); RC=$?
    fi
}

# The two always-on alerts as the live cluster actually emits them: vector(1)
# rules, so no namespace label at all.
DEADMEN='{"labels":{"alertname":"Watchdog","severity":"none"},"state":"firing"},
         {"labels":{"alertname":"AlertChannelHeartbeat","heartbeat":"true","severity":"info"},"state":"firing"}'
body() { printf '{"status":"success","data":{"alerts":[%s]}}' "$1"; }

# --- baseline: deadmen firing, nothing actionable ---------------------------
run "$(body "$DEADMEN")"
check "baseline: exit 0" 0 "$RC"
contains "baseline: no actionable alerts" "OK - No actionable alerts firing" "$OUT"
contains "baseline: lists the informational ones" "AlertChannelHeartbeat,Watchdog" "$OUT"
lacks "baseline: no missing deadman" "deadman alert(s) NOT firing" "$OUT"
contains "baseline: all checks passed" "All checks passed" "$OUT"
# Guard against a PATH mistake silently turning this into a live-cluster test.
contains "baseline: the fake kubectl was the one called" "get --raw" "$(cat "$MT_TEST_CALLS")"
lacks "baseline: no unscripted kubectl call" "unscripted call" "$OUT"

# --- a real actionable alert is still counted -------------------------------
CERT='{"labels":{"alertname":"CertificateNotReady","severity":"warning","namespace":"infra-cert-manager","name":"placeholder-tls"},"state":"firing"}'
run "$(body "$DEADMEN,$CERT,$CERT")"
check "two warnings: exit 1" 1 "$RC"
contains "two warnings: detail line" "[warning] CertificateNotReady (infra-cert-manager)" "$OUT"
contains "two warnings: counted once as an issue" "1 issue(s) found" "$OUT"
lacks "two warnings: does not claim there are none" "OK - No actionable alerts firing" "$OUT"
# pending alerts are not firing and must not be counted
PENDING='{"labels":{"alertname":"CertificateExpiringSoon","severity":"warning","namespace":"infra-cert-manager"},"state":"pending"}'
run "$(body "$DEADMEN,$PENDING")"
check "pending alert: exit 0" 0 "$RC"
contains "pending alert: not counted" "OK - No actionable alerts firing" "$OUT"

# --- MEDIUM 1: newline injection in a label value ---------------------------
# Reproduced by the reviewer: this used to print "OK - No actionable alerts
# firing" with ISSUES=0 because TOTAL came back as two lines.
INJ_SEV='{"labels":{"alertname":"Pwned","severity":"critical\nTOTAL:0","namespace":"infra-db"},"state":"firing"}'
run "$(body "$DEADMEN,$INJ_SEV")"
check "injected severity: exit 1" 1 "$RC"
lacks "injected severity: does not fail open" "OK - No actionable alerts firing" "$OUT"
lacks "injected severity: no integer-expression error" "integer expression expected" "$OUT"
contains "injected severity: alert is reported, newline flattened" "[critical TOTAL:0] Pwned (infra-db)" "$OUT"

# Same trick through alertname and namespace — all three are interpolated.
INJ_NAME='{"labels":{"alertname":"Pwned\nTOTAL:0","severity":"critical"},"state":"firing"}'
run "$(body "$DEADMEN,$INJ_NAME")"
check "injected alertname: exit 1" 1 "$RC"
lacks "injected alertname: does not fail open" "OK - No actionable alerts firing" "$OUT"
contains "injected alertname: reported flattened" "[critical] Pwned TOTAL:0" "$OUT"

INJ_NS='{"labels":{"alertname":"Pwned","severity":"critical","namespace":"infra-db\nTOTAL:0"},"state":"firing"}'
run "$(body "$DEADMEN,$INJ_NS")"
check "injected namespace: exit 1" 1 "$RC"
lacks "injected namespace: does not fail open" "OK - No actionable alerts firing" "$OUT"
contains "injected namespace: reported flattened" "(infra-db TOTAL:0)" "$OUT"

# A carriage return splits lines for `sed` on some platforms too.
INJ_CR='{"labels":{"alertname":"Pwned","severity":"critical\rTOTAL:0"},"state":"firing"}'
run "$(body "$DEADMEN,$INJ_CR")"
check "injected CR: exit 1" 1 "$RC"
lacks "injected CR: does not fail open" "OK - No actionable alerts firing" "$OUT"

# Injecting a fake deadman line must not silence the deadman check either.
INJ_MISSING='{"labels":{"alertname":"Pwned\nMISSING:","severity":"critical"},"state":"firing"}'
run "$(body "$INJ_MISSING")"
check "injected MISSING: exit 1" 1 "$RC"
contains "injected MISSING: deadmen still reported absent" "deadman alert(s) NOT firing: Watchdog,AlertChannelHeartbeat" "$OUT"

# --- MEDIUM 2: a 200 that is not a successful alert response ----------------
# The body is not a Prometheus alert response at all, so the alert list must be
# reported as unreadable — not silently as empty. Each case is run twice: once
# with ALERT_DEADMAN passed explicitly and once with it unset, because before
# the fix the deadman check was the only thing that failed the run, and it
# blamed the alert path rather than the body.
run '{"status":"error","error":"rule evaluation broken"}' ''
check "error body + no deadman: exit 1" 1 "$RC"
contains "error body + no deadman: says it could not parse" "could not be parsed" "$OUT"
lacks "error body + no deadman: does not claim no alerts" "OK - No actionable alerts firing" "$OUT"
lacks "error body + no deadman: does not pass" "All checks passed" "$OUT"

run '{"status":"success","data":"alerts"}' ''
check "data is not an object: exit 1" 1 "$RC"
contains "data is not an object: reported" "could not be parsed" "$OUT"

run '{"status":"success","data":{"alerts":{"state":"firing"}}}' ''
check "alerts is not a list: exit 1" 1 "$RC"
contains "alerts is not a list: reported" "could not be parsed" "$OUT"

run '{"status":"success","data":{"result":[]}}' ''
check "query response instead of an alert response: exit 1" 1 "$RC"
contains "query response instead of an alert response: reported" "could not be parsed" "$OUT"

run '<html><body>503 Service Unavailable</body></html>' ''
check "html body: exit 1" 1 "$RC"
contains "html body: reported" "could not be parsed" "$OUT"

# The same bad bodies with the deadman check left on must also fail — the
# fix must not depend on ALERT_DEADMAN being set.
run '{"status":"error","error":"rule evaluation broken"}'
check "error body, deadman on: exit 1" 1 "$RC"
contains "error body, deadman on: parse error, not a missing deadman" "could not be parsed" "$OUT"
lacks "error body, deadman on: does not claim no alerts" "OK - No actionable alerts firing" "$OUT"

# The one shape that ONLY the explicit status check catches: status is "error"
# but data.alerts is a well-formed empty list, so every .get() below succeeds
# and nothing raises. Without the `status != 'success'` clause this prints
# "OK - No actionable alerts firing" and then blames the deadman path.
# Mutation-tested: deleting that clause leaves the rest of this suite green.
run '{"status":"error","error":"rule evaluation broken","data":{"alerts":[]}}'
check "error status with a well-formed empty alert list: exit 1" 1 "$RC"
contains "error status with a well-formed empty alert list: reported as unparseable" "could not be parsed" "$OUT"
lacks "error status with a well-formed empty alert list: does not claim no alerts" "OK - No actionable alerts firing" "$OUT"

# --- LOW 1: a deadman is only satisfied by the cluster-wide rule ------------
# Both shipped deadmen are vector(1) rules with no namespace label, so an alert
# of the same name from some other namespace must not stand in for one.
NS_WATCHDOG='{"labels":{"alertname":"Watchdog","severity":"none","namespace":"infra-db"},"state":"firing"}'
run "$(body "$NS_WATCHDOG,{\"labels\":{\"alertname\":\"AlertChannelHeartbeat\",\"severity\":\"info\"},\"state\":\"firing\"}")"
check "namespaced Watchdog: exit 1" 1 "$RC"
contains "namespaced Watchdog: still reported missing" "deadman alert(s) NOT firing: Watchdog" "$OUT"
lacks "namespaced Watchdog: the real heartbeat is not reported missing" "Watchdog,AlertChannelHeartbeat" "$OUT"

# A pending (not firing) deadman is also absent.
run '{"status":"success","data":{"alerts":[{"labels":{"alertname":"Watchdog","severity":"none"},"state":"pending"},{"labels":{"alertname":"AlertChannelHeartbeat","severity":"info"},"state":"firing"}]}}'
check "pending Watchdog: exit 1" 1 "$RC"
contains "pending Watchdog: reported missing" "deadman alert(s) NOT firing: Watchdog" "$OUT"

# --- the alert API being unreadable is an issue, not a skip -----------------
: > "$MT_TEST_CALLS"; : > "$MT_TEST_STDOUT"; echo 1 > "$MT_TEST_RC"
OUT=$("${CLEAN_ENV[@]}" -u ALERT_DEADMAN PATH="$TMP/bin:$PATH" KUBECONFIG="$TMP/kubeconfig" \
          bash "$SCRIPT" -e test 2>&1); RC=$?
check "kubectl fails: exit 1" 1 "$RC"
contains "kubectl fails: reported" "Could not query the Prometheus alert API" "$OUT"
lacks "kubectl fails: does not pass" "All checks passed" "$OUT"

# --- Check 7 is counted, so stubbing it above cannot hide a broken gate -----
# Without this the default MT_TEST_REFLECTOR_RC=0 would make the stub
# indistinguishable from check-health having dropped Check 7 altogether.
run "$(body "$DEADMEN")"
check "reflector gate passing: exit 0" 0 "$RC"
contains "reflector gate passing: mirrors reported in sync" "Wildcard TLS mirrors in sync" "$OUT"

: > "$MT_TEST_CALLS"; printf '%s' "$(body "$DEADMEN")" > "$MT_TEST_STDOUT"; echo 0 > "$MT_TEST_RC"
OUT=$(MT_TEST_REFLECTOR_RC=1 "${CLEAN_ENV[@]}" -u ALERT_DEADMAN PATH="$TMP/bin:$PATH"           KUBECONFIG="$TMP/kubeconfig" bash "$SCRIPT" -e test 2>&1); RC=$?
check "reflector gate failing: exit 1" 1 "$RC"
contains "reflector gate failing: counted as an issue" "1 issue(s) found" "$OUT"
lacks "reflector gate failing: does not claim all passed" "All checks passed" "$OUT"

echo "check-health-alerts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
