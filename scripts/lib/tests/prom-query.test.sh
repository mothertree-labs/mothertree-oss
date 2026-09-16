#!/usr/bin/env bash
# Unit tests for mt_prom_http / mt_prom_query in scripts/lib/common.sh — the
# Prometheus readers used by scripts/infra-health-gate (a FATAL CI gate) and
# scripts/check-health.
#
# They talk to Prometheus through the API server's service proxy
# (`kubectl get --raw /api/v1/namespaces/<ns>/services/<svc>:<port>/proxy/...`)
# because kube-prometheus-stack 85 made the Prometheus image distroless: there
# is no wget and no shell to exec into any more. The invariant that matters is
# that a failed read is NEVER indistinguishable from "no series" — the gate
# would then pass vacuously. Runs against a fake kubectl; no cluster needed.
# Invoked by ci/scripts/shell-unit-tests.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Cleared before sourcing: they are documented environment overrides, so a
# shell that exports one would make the two default-value assertions below
# read back its value instead of the chart's name and fail the suite.
unset MT_PROM_SERVICE MT_PROM_PORT
# shellcheck source=../common.sh
source "$HERE/../common.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Point TMPDIR at our own dir so mt_prom_http's mktemp lands here. The leak
# assertion below counts files in TMPDIR, and a shared /tmp is not hermetic:
# any stray mt-prom-http.* from another run, a concurrent suite, or a mutation
# test of this very assertion would fail it for reasons unrelated to the code.
export TMPDIR="$TMP"
mkdir -p "$TMP/bin"
export MT_TEST_CALLS="$TMP/calls" MT_TEST_PATHS="$TMP/paths"
export MT_TEST_RC="$TMP/rc" MT_TEST_STDOUT="$TMP/stdout" MT_TEST_STDERR="$TMP/stderr"
# The fake records the --raw path it was given and replays scripted
# stdout/stderr/exit code — the three things a real `kubectl get --raw` varies.
cat > "$TMP/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "kubectl $*" >> "$MT_TEST_CALLS"
case " $* " in
    *" get --raw "*)
        while [ $# -gt 0 ]; do [ "$1" = "--raw" ] && { printf '%s\n' "$2" >> "$MT_TEST_PATHS"; break; }; shift; done
        cat "$MT_TEST_STDERR" >&2
        cat "$MT_TEST_STDOUT"
        exit "$(cat "$MT_TEST_RC")" ;;
esac
echo "fake-kubectl: unscripted call: $*" >&2; exit 99
FAKE
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH"

PASS=0; FAIL=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: expected [$2] got [$3]"; fi
}
contains() {  # contains <description> <needle> <haystack>
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); echo "FAIL: $1: [$2] not in: $3" ;; esac
}
scenario() {  # scenario <rc> <stdout> [stderr]
    : > "$MT_TEST_CALLS"; : > "$MT_TEST_PATHS"
    echo "$1" > "$MT_TEST_RC"; printf '%s' "$2" > "$MT_TEST_STDOUT"; printf '%s' "${3:-}" > "$MT_TEST_STDERR"
}
OK_BODY='{"status":"success","data":{"resultType":"vector","result":[{"metric":{"__name__":"up","job":"kube-state-metrics"},"value":[1757980000,"1"]}]}}'
EMPTY_BODY='{"status":"success","data":{"resultType":"vector","result":[]}}'

# --- defaults are the chart's stable names, overridable from the environment --
check "default service" "kube-prometheus-stack-prometheus" "$MT_PROM_SERVICE"
check "default port" "9090" "$MT_PROM_PORT"

# --- happy path: the result array is printed, nothing else -------------------
scenario 0 "$OK_BODY"
out=$(mt_prom_query infra-monitoring kube-prometheus-stack-prometheus 9090 'up{job=~".*kube-state-metrics.*"} == 1' 2>"$TMP/err"); rc=$?
check "query ok: rc" 0 "$rc"
check "query ok: prints .data.result" '[{"metric":{"__name__":"up","job":"kube-state-metrics"},"value":[1757980000,"1"]}]' "$out"
check "query ok: length is usable by jq" 1 "$(jq 'length' <<< "$out")"
check "query ok: nothing on stderr" "" "$(cat "$TMP/err")"
check "query ok: one kubectl call" 1 "$(grep -c 'get --raw' "$MT_TEST_CALLS")"
check "query ok: goes through the service proxy with ns/svc/port and the encoded query" \
  '/api/v1/namespaces/infra-monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=up%7Bjob%3D~%22.%2Akube-state-metrics.%2A%22%7D%20%3D%3D%201' \
  "$(cat "$MT_TEST_PATHS")"
contains "query ok: never execs into the container" "get --raw" "$(cat "$MT_TEST_CALLS")"
case "$(cat "$MT_TEST_CALLS")" in *" exec "*) check "query ok: no kubectl exec" no yes ;; *) check "query ok: no kubectl exec" no no ;; esac

# --- an empty result is a legitimate success, distinct from a failure --------
scenario 0 "$EMPTY_BODY"
out=$(mt_prom_query infra-monitoring svc 9090 'up == 0' 2>/dev/null); rc=$?
check "empty result: rc 0" 0 "$rc"
check "empty result: empty array" "[]" "$out"

# --- kubectl non-zero -> non-zero, never an empty-but-successful answer ------
scenario 1 "" "Error from server (NotFound): services \"kube-prometheus-stack-prometheus\" not found"
out=$(mt_prom_query infra-monitoring kube-prometheus-stack-prometheus 9090 'up == 1' 2>"$TMP/err"); rc=$?
check "kubectl fails: rc non-zero" 1 "$rc"
check "kubectl fails: nothing on stdout (caller must not read it as 'no series')" "" "$out"
contains "kubectl fails: echoes kubectl's own stderr" 'services "kube-prometheus-stack-prometheus" not found' "$(cat "$TMP/err")"
contains "kubectl fails: names the service and namespace" "service kube-prometheus-stack-prometheus:9090 in infra-monitoring" "$(cat "$TMP/err")"
contains "kubectl fails: names the failing query" "up == 1" "$(cat "$TMP/err")"
# The proxy cannot tell a transport failure from a rejected query, so the
# message must not claim it can (a BadRequest from invalid PromQL looks the same).
case "$(cat "$TMP/err")" in *"(transport)"*) check "kubectl fails: does not claim 'transport'" no yes ;; *) check "kubectl fails: does not claim 'transport'" no no ;; esac
contains "kubectl fails: says which possibilities" "unreachable, denied, or invalid PromQL" "$(cat "$TMP/err")"

# --- invalid PromQL comes back as a kubectl BadRequest, still non-zero -------
scenario 1 "" "Error from server (BadRequest): the server rejected our request for an unknown reason"
out=$(mt_prom_query infra-monitoring svc 9090 'up{{{' 2>"$TMP/err"); rc=$?
check "bad promql: rc non-zero" 1 "$rc"
check "bad promql: no stdout" "" "$out"
contains "bad promql: shows the API error" "BadRequest" "$(cat "$TMP/err")"

# --- rc 0 with a non-JSON body (proxy/error page) is a failure, not empty ----
scenario 0 '<html><body>503 Service Unavailable</body></html>'
out=$(mt_prom_query infra-monitoring svc 9090 'up == 1' 2>"$TMP/err"); rc=$?
check "html body: rc non-zero" 1 "$rc"
check "html body: no stdout" "" "$out"
contains "html body: explains" "not a successful Prometheus result" "$(cat "$TMP/err")"
contains "html body: shows the body" "503 Service Unavailable" "$(cat "$TMP/err")"

# --- rc 0 with a Prometheus error body is a failure -------------------------
scenario 0 '{"status":"error","errorType":"bad_data","error":"invalid parameter"}'
out=$(mt_prom_query infra-monitoring svc 9090 'up == 1' 2>"$TMP/err"); rc=$?
check "error body: rc non-zero" 1 "$rc"
check "error body: no stdout" "" "$out"
contains "error body: shows Prometheus's message" "invalid parameter" "$(cat "$TMP/err")"

# --- rc 0 with an empty body is a failure, not "no series" ------------------
scenario 0 ''
out=$(mt_prom_query infra-monitoring svc 9090 'up == 1' 2>/dev/null); rc=$?
check "empty body: rc non-zero" 1 "$rc"
check "empty body: no stdout" "" "$out"

# --- mt_prom_http: non-query paths (check-health reads api/v1/alerts) -------
scenario 0 '{"status":"success","data":{"alerts":[{"state":"firing"},{"state":"pending"}]}}'
out=$(mt_prom_http infra-monitoring kube-prometheus-stack-prometheus 9090 'api/v1/alerts' 2>/dev/null); rc=$?
check "http alerts: rc" 0 "$rc"
check "http alerts: raw body returned verbatim" 2 "$(jq '.data.alerts | length' <<< "$out")"
check "http alerts: path has no query string" \
  '/api/v1/namespaces/infra-monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/alerts' "$(cat "$MT_TEST_PATHS")"
scenario 0 '{"ok":true}'
mt_prom_http infra-monitoring svc 9090 '/api/v1/alerts' >/dev/null 2>&1
check "http: a leading slash in the path is tolerated" \
  '/api/v1/namespaces/infra-monitoring/services/svc:9090/proxy/api/v1/alerts' "$(cat "$MT_TEST_PATHS")"
scenario 1 "" "Error from server (Forbidden): services \"svc\" is forbidden"
out=$(mt_prom_http infra-monitoring svc 9090 'api/v1/alerts' 2>"$TMP/err"); rc=$?
check "http fails: rc non-zero" 1 "$rc"
check "http fails: no stdout" "" "$out"
contains "http fails: names the path without the query string" "api/v1/alerts" "$(cat "$TMP/err")"
contains "http fails: echoes kubectl's stderr" "Forbidden" "$(cat "$TMP/err")"

# --- rc 0, status success, but no .data.result array ------------------------
# `jq -c .data.result` on such a body prints `null`: rc 0, and `jq length`
# reports 0, which scripts/infra-health-gate reads as "no series" and passes on.
scenario 0 '{"status":"success","data":{"resultType":"vector"}}'
out=$(mt_prom_query infra-monitoring svc 9090 'up == 1' 2>"$TMP/err"); rc=$?
check "missing .data.result: rc non-zero" 1 "$rc"
check "missing .data.result: no stdout (never 'null')" "" "$out"
contains "missing .data.result: explains" "no .data.result array" "$(cat "$TMP/err")"

scenario 0 '{"status":"success","data":{"result":null}}'
out=$(mt_prom_query infra-monitoring svc 9090 'up == 1' 2>/dev/null); rc=$?
check "null .data.result: rc non-zero" 1 "$rc"
check "null .data.result: no stdout" "" "$out"

scenario 0 '{"status":"success","data":{"result":{"metric":{}}}}'
out=$(mt_prom_query infra-monitoring svc 9090 'up == 1' 2>/dev/null); rc=$?
check "non-array .data.result: rc non-zero" 1 "$rc"
check "non-array .data.result: no stdout" "" "$out"

# ...but a legitimately empty array is still a success (regression guard for
# the check above: it must reject the shape, not the emptiness).
scenario 0 "$EMPTY_BODY"
out=$(mt_prom_query infra-monitoring svc 9090 'up == 0' 2>/dev/null); rc=$?
check "empty array survives the result-shape check: rc 0" 0 "$rc"
check "empty array survives the result-shape check: []" "[]" "$out"

# --- ns/svc/port are validated before the proxy path is built ---------------
# MT_PROM_SERVICE/MT_PROM_PORT are documented environment overrides and the
# path is plain concatenation, so a traversal value would escape the
# service-proxy subtree and GET an arbitrary API-server resource.
_rejects() {  # _rejects <description> <ns> <svc> <port>
    scenario 0 "$OK_BODY"
    local out rc
    out=$(mt_prom_http "$2" "$3" "$4" 'api/v1/alerts' 2>"$TMP/err"); rc=$?
    check "$1: rc non-zero" 1 "$rc"
    check "$1: no stdout" "" "$out"
    check "$1: kubectl never called" 0 "$(wc -l < "$MT_TEST_CALLS" | tr -d ' ')"
    contains "$1: says what it refused" "refusing a non-Service target" "$(cat "$TMP/err")"
}
_rejects "service path traversal" infra-monitoring '../../../../apis/apps/v1/namespaces/default/deployments' 9090
_rejects "service with a slash" infra-monitoring 'svc/proxy' 9090
_rejects "namespace traversal" '../../../nodes' svc 9090
_rejects "non-numeric port" infra-monitoring svc '9090/proxy/x'
_rejects "port with a shell metacharacter" infra-monitoring svc '9090;id'
_rejects "uppercase service (not a DNS-1123 label)" infra-monitoring 'Svc' 9090
_rejects "empty-ish service" infra-monitoring '-svc' 9090
# mt_prom_query refuses the same values, through mt_prom_http.
scenario 0 "$OK_BODY"
out=$(mt_prom_query infra-monitoring '../../../../api/v1/nodes' 9090 'up' 2>/dev/null); rc=$?
check "query: traversal service rejected" 1 "$rc"
check "query: traversal service produces no stdout" "" "$out"
check "query: traversal service never reaches kubectl" 0 "$(wc -l < "$MT_TEST_CALLS" | tr -d ' ')"

# --- every read carries a request timeout -----------------------------------
# kubectl's default is 0 == wait forever. infra-health-gate is a FATAL CI gate
# that re-samples for minutes, so a hung API server must fail it, not hang it.
scenario 0 "$OK_BODY"
mt_prom_query infra-monitoring svc 9090 'up' >/dev/null 2>&1
contains "query: passes --request-timeout to kubectl" "--request-timeout=30s" "$(cat "$MT_TEST_CALLS")"
scenario 0 '{"status":"success","data":{"alerts":[]}}'
mt_prom_http infra-monitoring svc 9090 'api/v1/alerts' >/dev/null 2>&1
contains "http: passes --request-timeout to kubectl" "--request-timeout=30s" "$(cat "$MT_TEST_CALLS")"

# --- the port is honoured, not hardcoded ------------------------------------
scenario 0 "$OK_BODY"
mt_prom_query other-ns other-svc 19090 'up' >/dev/null 2>&1
contains "custom ns/svc/port are used verbatim" '/api/v1/namespaces/other-ns/services/other-svc:19090/proxy/' "$(cat "$MT_TEST_PATHS")"

# --- no temp files left behind (mt_prom_http uses one for kubectl's stderr) --
scenario 1 "" "boom"
mt_prom_http infra-monitoring svc 9090 'api/v1/alerts' >/dev/null 2>&1
scenario 0 "$OK_BODY"
mt_prom_query infra-monitoring svc 9090 'up' >/dev/null 2>&1
check "no mt-prom-http temp files leak" 0 "$(find "$TMPDIR" -maxdepth 1 -name 'mt-prom-http.*' 2>/dev/null | wc -l | tr -d ' ')"

echo "prom-query: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
