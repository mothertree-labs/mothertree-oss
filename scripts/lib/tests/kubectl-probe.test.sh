#!/usr/bin/env bash
# Unit tests for the explicit-verdict probe helpers in scripts/lib/common.sh
# (issue #623): mt_kubectl_probe, mt_probe_exec, mt_probe_job, mt_kubectl_logs,
# mt_coredns_rewrite_verify, plus mt_coredns_rewrite_require (#662) and
# mt_delete_job_wait (#667). Runs against a fake kubectl (fake-kubectl.sh) —
# no cluster needed. Invoked by ci/scripts/shell-unit-tests.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "$HERE/../common.sh"

export MT_PROBE_BACKOFF_BASE=0 MT_PROBE_POLL_INTERVAL=0 MT_JOB_DELETE_POLL_INTERVAL=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cp "$HERE/fake-kubectl.sh" "$TMP/bin/kubectl"; chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH"
export MT_TEST_CALLS="$TMP/calls" MT_TEST_MANIFEST="$TMP/manifest.json" MT_TEST_STATE="$TMP/state"

PASS=0; FAIL=0
scenario() { export MT_TEST_SCENARIO="$1"; rm -rf "$MT_TEST_STATE" "$MT_TEST_CALLS" "$MT_TEST_MANIFEST"; mkdir -p "$MT_TEST_STATE"; : > "$MT_TEST_CALLS"; }
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: expected [$2] got [$3]"; fi
}
count_calls() { grep -c "$1" "$MT_TEST_CALLS" || true; }

# --- exec transport ----------------------------------------------------------
scenario exec-ok
mt_kubectl_probe "t" 3 mt_probe_exec ns pod ctr -- php -r 'x' >/dev/null; rc=$?
check "exec-ok rc" 0 "$rc"; check "exec-ok verdict" OK "$MT_PROBE_VERDICT"
check "exec-ok detail" "system=1 marker=1 session=1" "$MT_PROBE_DETAIL"
check "exec-ok single call" 1 "$(count_calls ' exec ')"

scenario exec-missing
mt_kubectl_probe "t" 3 mt_probe_exec ns pod ctr -- x >/dev/null; rc=$?
check "exec-missing rc" 1 "$rc"; check "exec-missing verdict" MISSING "$MT_PROBE_VERDICT"
check "exec-missing no retry" 1 "$(count_calls ' exec ')"

scenario exec-lost
mt_kubectl_probe "t" 3 mt_probe_exec ns pod ctr -- x >/dev/null; rc=$?
check "lost attach rc" 2 "$rc"; check "lost attach verdict" UNKNOWN "$MT_PROBE_VERDICT"
check "lost attach retried 3x" 3 "$(count_calls ' exec ')"
case "$MT_PROBE_OUTPUT" in *"unable to upgrade connection"*) check "lost attach output kept" y y ;; *) check "lost attach output kept" y n ;; esac

scenario exec-empty
mt_kubectl_probe "t" 2 mt_probe_exec ns pod ctr -- x >/dev/null; rc=$?
check "empty output rc" 2 "$rc"; check "empty output verdict" UNKNOWN "$MT_PROBE_VERDICT"

scenario exec-timeout
mt_kubectl_probe "t" 2 mt_probe_exec ns pod ctr -- x >/dev/null; rc=$?
check "timeout rc" 2 "$rc"; check "timeout retried 2x" 2 "$(count_calls ' exec ')"

scenario exec-chatter-only
mt_kubectl_probe "t" 1 mt_probe_exec ns pod ctr -- x >/dev/null; rc=$?
check "old token / inexact sentinel is not a verdict" UNKNOWN "$MT_PROBE_VERDICT"

scenario exec-contradictory
mt_kubectl_probe "t" 1 mt_probe_exec ns pod ctr -- x >/dev/null; rc=$?
check "contradictory rc" 2 "$rc"; check "contradictory verdict" UNKNOWN "$MT_PROBE_VERDICT"

scenario exec-retry-then-ok
mt_kubectl_probe "t" 3 mt_probe_exec ns pod ctr -- x >/dev/null; rc=$?
check "retry-then-ok rc" 0 "$rc"; check "retry-then-ok calls" 2 "$(count_calls ' exec ')"

scenario exec-retry-then-missing
mt_kubectl_probe "t" 3 mt_probe_exec ns pod ctr -- x >/dev/null; rc=$?
check "retry-then-missing rc" 1 "$rc"; check "retry-then-missing calls" 3 "$(count_calls ' exec ')"

scenario exec-retry-then-ok
mt_kubectl_probe "t" 1 mt_probe_exec ns pod ctr -- x >/dev/null; rc=$?
check "attempts=1 gives up after one lost attach" 2 "$rc"

# A transport function that itself prints nothing and returns non-zero
# (e.g. no Running pod) is UNKNOWN, never MISSING.
scenario exec-ok
no_pod() { echo "no Running pod"; return 1; }
mt_kubectl_probe "t" 2 no_pod >/dev/null; rc=$?
check "no-pod transport rc" 2 "$rc"; check "no-pod verdict" UNKNOWN "$MT_PROBE_VERDICT"

# --- job transport -----------------------------------------------------------
scenario job-ok
mt_kubectl_probe "t" 3 mt_probe_job infra-db nc-probe postgres:17-alpine \
    --env-from-secret "PGPASSWORD=postgres-credentials/postgres-password" --env "NC_DB=nextcloud_x" --timeout 5 \
    -- sh -c 'echo "a b"' >/dev/null; rc=$?
check "job-ok rc" 0 "$rc"; check "job-ok verdict" OK "$MT_PROBE_VERDICT"
check "job-ok deleted" 1 "$(count_calls ' delete job ')"
check "manifest kind" Job "$(jq -r .kind "$MT_TEST_MANIFEST")"
check "manifest backoffLimit" 0 "$(jq -r .spec.backoffLimit "$MT_TEST_MANIFEST")"
check "manifest deadline" 5 "$(jq -r .spec.activeDeadlineSeconds "$MT_TEST_MANIFEST")"
check "manifest restartPolicy" Never "$(jq -r .spec.template.spec.restartPolicy "$MT_TEST_MANIFEST")"
check "manifest command preserved" 'sh|-c|echo "a b"' "$(jq -r '.spec.template.spec.containers[0].command | join("|")' "$MT_TEST_MANIFEST")"
check "manifest secret env" postgres-credentials "$(jq -r '.spec.template.spec.containers[0].env[] | select(.name=="PGPASSWORD") | .valueFrom.secretKeyRef.name' "$MT_TEST_MANIFEST")"
check "manifest secret key" postgres-password "$(jq -r '.spec.template.spec.containers[0].env[] | select(.name=="PGPASSWORD") | .valueFrom.secretKeyRef.key' "$MT_TEST_MANIFEST")"
check "manifest literal env" nextcloud_x "$(jq -r '.spec.template.spec.containers[0].env[] | select(.name=="NC_DB") | .value' "$MT_TEST_MANIFEST")"
case "$(cat "$MT_TEST_MANIFEST")" in *"PGPASSWORD\":{\"value"*) check "no secret literal in manifest" y n ;; *) check "no secret literal in manifest" y y ;; esac

scenario job-failed-with-verdict
mt_kubectl_probe "t" 3 mt_probe_job ns p img --timeout 5 -- sh -c x >/dev/null; rc=$?
check "failed job still yields its verdict" FAIL "$MT_PROBE_VERDICT"; check "failed job rc" 1 "$rc"
check "failed job not retried" 1 "$(count_calls 'apply -f -')"

scenario job-timeout
mt_kubectl_probe "t" 2 mt_probe_job ns p img --timeout 0 -- sh -c x >/dev/null; rc=$?
check "job timeout rc" 2 "$rc"; check "job timeout verdict" UNKNOWN "$MT_PROBE_VERDICT"
check "job timeout retried (2 jobs created)" 2 "$(count_calls 'apply -f -')"
check "job timeout cleaned up both" 2 "$(count_calls ' delete job ')"
check "job timeout never fetched logs" 0 "$(count_calls ' logs ')"

scenario job-logs-flake
mt_kubectl_probe "t" 1 mt_probe_job ns p img --timeout 5 -- sh -c x >/dev/null; rc=$?
check "logs flake then ok rc" 0 "$rc"; check "logs fetched twice" 2 "$(count_calls ' logs ')"

scenario job-get-flake-then-ok
mt_kubectl_probe "t" 1 mt_probe_job ns p img --timeout 5 -- sh -c x >/dev/null; rc=$?
check "status poll keeps polling until terminal" 0 "$rc"

scenario job-apply-fail
mt_kubectl_probe "t" 2 mt_probe_job ns p img --timeout 5 -- sh -c x >/dev/null; rc=$?
check "apply failure rc" 2 "$rc"; check "apply failure verdict" UNKNOWN "$MT_PROBE_VERDICT"
case "$MT_PROBE_OUTPUT" in *"could not create job"*) check "apply failure explained" y y ;; *) check "apply failure explained" y n ;; esac

out=$(mt_probe_job ns p img --bogus -- x 2>&1); rc=$?
check "unknown option rejected" 2 "$rc"
out=$(mt_probe_job ns p img --timeout 5 2>&1); rc=$?
check "missing command rejected" 2 "$rc"

# --- mt_kubectl_logs ---------------------------------------------------------
scenario logs-flake-then-ok
out=$(mt_kubectl_logs -- -n ns job/x); rc=$?
check "logs retry rc" 0 "$rc"; check "logs retry output" $'line1\nline2' "$out"

scenario logs-always-fail
out=$(mt_kubectl_logs 2 -- -n ns job/x); rc=$?
check "logs give-up rc" 1 "$rc"; check "logs give-up attempts" 2 "$(count_calls ' logs ')"
case "$out" in "[mt_kubectl_logs: fetch FAILED after 2 attempts:"*) check "logs give-up marker" y y ;; *) check "logs give-up marker" y "n: $out" ;; esac

# --- mt_coredns_rewrite_verify ----------------------------------------------
scenario coredns-ok
out=$(mt_coredns_rewrite_verify tn-x-mail mail.example.com 10.128.0.7); rc=$?
check "coredns verify rc" 0 "$rc"
check "coredns pod ips exclude Terminating" "10.2.0.5 " "$(jq -r '.spec.template.spec.containers[0].env[] | select(.name=="PROBE_POD_IPS") | .value' "$MT_TEST_MANIFEST")"
check "coredns want ip" 10.128.0.7 "$(jq -r '.spec.template.spec.containers[0].env[] | select(.name=="PROBE_WANT") | .value' "$MT_TEST_MANIFEST")"
check "coredns image pinned" busybox:1.36 "$(jq -r '.spec.template.spec.containers[0].image' "$MT_TEST_MANIFEST")"
case "$(jq -r '.spec.template.spec.containers[0].command[2]' "$MT_TEST_MANIFEST")" in *"MT_PROBE_VERDICT=FAIL"*) check "coredns script carries sentinels" y y ;; *) check "coredns script carries sentinels" y n ;; esac

scenario coredns-none
out=$(mt_coredns_rewrite_verify tn-x-mail mail.example.com 10.128.0.7); rc=$?
check "coredns no pods rc" 2 "$rc"

# --- mt_coredns_rewrite_require (#662) --------------------------------------
# Policy split: a definite "not converged" aborts the deploy; "could not
# determine" must NOT, because it says nothing about the rewrite. Collapsing the
# two is what let a lost attach on a rebuilt dev cluster fail deploy-dev-llm and
# strand two merged PRs short of production.
_saved_verify=$(declare -f mt_coredns_rewrite_verify)

mt_coredns_rewrite_verify() { return 0; }
mt_coredns_rewrite_require ns host 1.2.3.4 >/dev/null 2>&1; rc=$?
check "require: converged -> proceed" 0 "$rc"

mt_coredns_rewrite_verify() { return 1; }
mt_coredns_rewrite_require ns host 1.2.3.4 >/dev/null 2>&1; rc=$?
check "require: NOT converged -> abort" 1 "$rc"

mt_coredns_rewrite_verify() { return 2; }
out=$(mt_coredns_rewrite_require ns host 1.2.3.4 2>&1); rc=$?
check "require: no verdict -> proceed" 0 "$rc"
case "$out" in *"not evidence the rewrite failed"*) check "require: no-verdict warns loudly" y y ;;
               *)                                   check "require: no-verdict warns loudly" y n ;; esac

eval "$_saved_verify"   # restore the real implementation

# --- mt_delete_job_wait (#667) ----------------------------------------------
# `kubectl delete job` can return before the API server drops the object, so
# delete-then-recreate races and fails with AlreadyExists. The helper must not
# return until the Job is actually gone.
_dj_state="$TMP/dj"
kubectl() {  # local stub: shell function wins over the fake on PATH
    case "$*" in
        "get job "*)
            case "$MT_DJ_SCENARIO" in
                absent)   echo 'Error from server (NotFound): jobs.batch "myjob" not found' >&2; return 1 ;;
                vanishes) n=$(( $(cat "$_dj_state" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$_dj_state"
                          if [ "$n" -ge 3 ]; then echo 'Error from server (NotFound): jobs.batch "myjob" not found' >&2; return 1; fi
                          return 0 ;;
                stuck)    return 0 ;;
                # transport failure: NOT an answer, must never read as "absent"
                unreadable) echo 'Unable to connect to the server: dial tcp: i/o timeout' >&2; return 1 ;;
            esac ;;
        *delete*) return 0 ;;
    esac
}

MT_DJ_SCENARIO=absent; : > "$_dj_state"
mt_delete_job_wait ns myjob >/dev/null 2>&1; rc=$?
check "delete_job_wait: already absent -> 0, no delete" 0 "$rc"

MT_DJ_SCENARIO=vanishes; echo 0 > "$_dj_state"
mt_delete_job_wait ns myjob >/dev/null 2>&1; rc=$?
check "delete_job_wait: gone after polling -> 0" 0 "$rc"

MT_DJ_SCENARIO=stuck; : > "$_dj_state"
out=$(mt_delete_job_wait ns myjob 2 2>&1); rc=$?
check "delete_job_wait: never gone -> 1 (do NOT recreate)" 1 "$rc"
case "$out" in *"AlreadyExists"*) check "delete_job_wait: error names the failure mode" y y ;;
               *)                 check "delete_job_wait: error names the failure mode" y n ;; esac

# A transport failure is not an answer: it must NOT be read as "job absent",
# which would return 0 and let the caller recreate into an existing Job (#623).
MT_DJ_SCENARIO=unreadable; : > "$_dj_state"
out=$(mt_delete_job_wait ns myjob 2 2>&1); rc=$?
check "delete_job_wait: unreadable state -> 1, not 'absent'" 1 "$rc"
case "$out" in *"cannot determine"*) check "delete_job_wait: says it could not determine" y y ;;
               *)                    check "delete_job_wait: says it could not determine" y n ;; esac

# Latent fail-open: a 0/non-numeric timeout made `seq` empty, so the loop never
# ran and the function fell through returning 0 -- "gone" without looking.
MT_DJ_SCENARIO=stuck; : > "$_dj_state"
mt_delete_job_wait ns myjob 0 >/dev/null 2>&1; rc=$?
check "delete_job_wait: timeout=0 does not fail open" 1 "$rc"
unset -f kubectl

echo "kubectl-probe.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
