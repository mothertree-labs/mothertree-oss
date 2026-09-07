#!/usr/bin/env bash
# Fake `kubectl` for scripts/lib/tests/*.test.sh — put its directory first in
# PATH. Behaviour is selected by MT_TEST_SCENARIO; every invocation is appended
# to $MT_TEST_CALLS, and a `kubectl apply -f -` manifest is saved to
# $MT_TEST_MANIFEST so tests can assert on what would have been created.
set -u
: "${MT_TEST_SCENARIO:?}" "${MT_TEST_CALLS:?}" "${MT_TEST_MANIFEST:?}" "${MT_TEST_STATE:?}"
printf '%s\n' "kubectl $*" >> "$MT_TEST_CALLS"

# Per-subcommand call counters (files under MT_TEST_STATE)
bump() { local f="$MT_TEST_STATE/$1" n; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$f"; echo "$n"; }

lost_attach() {
    echo "error: unable to upgrade connection: container not found (\"probe\")" >&2
    exit 1
}

case " $* " in
    *" exec "*)
        n=$(bump exec)
        case "$MT_TEST_SCENARIO" in
            exec-ok)            printf 'some chatter\nMT_PROBE_DETAIL=system=1 marker=1 session=1\nMT_PROBE_VERDICT=OK\n' ;;
            exec-missing)       printf 'MT_PROBE_DETAIL=system=1 marker=1 session=0\nMT_PROBE_VERDICT=MISSING\n' ;;
            exec-lost)          lost_attach ;;
            exec-timeout)       echo "error: timed out waiting for the condition" >&2; exit 1 ;;
            exec-empty)         exit 0 ;;
            exec-chatter-only)  printf 'RC_SCHEMA_OK\nMT_PROBE_VERDICT=OK trailing\n' ;;   # old token + a non-exact sentinel: NOT a verdict
            exec-contradictory) printf 'MT_PROBE_VERDICT=OK\nMT_PROBE_VERDICT=MISSING\n' ;;
            exec-retry-then-ok) if [ "$n" -lt 2 ]; then lost_attach; fi; printf 'MT_PROBE_VERDICT=OK\n' ;;
            exec-retry-then-missing) if [ "$n" -lt 3 ]; then lost_attach; fi; printf 'MT_PROBE_VERDICT=MISSING\n' ;;
            *) echo "fake-kubectl: exec not scripted for $MT_TEST_SCENARIO" >&2; exit 99 ;;
        esac
        exit 0 ;;
    *" apply -f - "*)
        cat > "$MT_TEST_MANIFEST"
        case "$MT_TEST_SCENARIO" in
            job-apply-fail) echo "error: dial tcp 10.0.0.1:443: connection refused" >&2; exit 1 ;;
        esac
        echo "job.batch/fake created"; exit 0 ;;
    *" get job "*)
        n=$(bump getjob)
        case "$MT_TEST_SCENARIO" in
            job-ok|job-logs-flake|coredns-ok)  [ "$n" -ge 2 ] && printf 'Complete ' ;;
            job-failed-with-verdict)           printf 'Failed ' ;;
            job-timeout)                       ;;   # never terminal
            job-get-flake-then-ok)             [ "$n" -ge 3 ] && printf 'Complete ' ;;
        esac
        exit 0 ;;
    *" logs "*)
        n=$(bump logs)
        case "$MT_TEST_SCENARIO" in
            job-ok|coredns-ok)        printf 'OK: all good\nMT_PROBE_VERDICT=OK\n' ;;
            job-failed-with-verdict)  printf 'FAIL: not converged\nMT_PROBE_VERDICT=FAIL\n' ;;
            job-logs-flake)           if [ "$n" -lt 2 ]; then echo "error: proxy error from konnectivity-server.kube-system.svc.cluster.local:8090" >&2; exit 1; fi
                                      printf 'MT_PROBE_VERDICT=OK\n' ;;
            job-get-flake-then-ok)    printf 'MT_PROBE_VERDICT=OK\n' ;;
            logs-always-fail)         echo "error: unable to upgrade connection" >&2; exit 1 ;;
            logs-flake-then-ok)       if [ "$n" -lt 2 ]; then echo "error: proxy error" >&2; exit 1; fi; printf 'line1\nline2\n' ;;
        esac
        exit 0 ;;
    *" delete job "*) exit 0 ;;
    *" get pods "*)
        case "$MT_TEST_SCENARIO" in
            coredns-ok) printf '{"items":[{"status":{"phase":"Running","podIP":"10.2.0.5"},"metadata":{}},{"status":{"phase":"Running","podIP":"10.2.0.9"},"metadata":{"deletionTimestamp":"2026-01-01T00:00:00Z"}}]}\n' ;;
            coredns-none) printf '{"items":[]}\n' ;;
        esac
        exit 0 ;;
esac
echo "fake-kubectl: unscripted call: $*" >&2
exit 99
