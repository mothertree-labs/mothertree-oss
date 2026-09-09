#!/usr/bin/env bash
# Unit tests for mt_apply / mt_restart_if_changed in scripts/lib/common.sh:
# change detection is a server-side `kubectl diff` (exit 0 = identical,
# 1 = differs), never the "configured" word in apply output. Runs against an
# inline fake kubectl — no cluster needed. Invoked by
# ci/scripts/shell-unit-tests.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "$HERE/../common.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export MT_TEST_CALLS="$TMP/calls" MT_TEST_DIFF_RC="$TMP/diff_rc" MT_TEST_APPLY_SAYS="$TMP/apply_says" MT_TEST_APPLY_RC="$TMP/apply_rc"
export MT_TEST_DIFF_IN="$TMP/diff_in" MT_TEST_APPLY_IN="$TMP/apply_in"
# The fake records every invocation, saves the manifest each subcommand read
# from stdin, prints leak-canary text on `diff` stdout (must never surface),
# and exits with the scripted code.
cat > "$TMP/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "kubectl $*" >> "$MT_TEST_CALLS"
case " $* " in
    *" diff "*)
        cat > "$MT_TEST_DIFF_IN"
        [ -z "${KUBECTL_EXTERNAL_DIFF:-}" ] || { echo "KUBECTL_EXTERNAL_DIFF leaked: $KUBECTL_EXTERNAL_DIFF" >&2; exit 7; }
        echo "+  SECRET-CANARY: hunter2"          # stdout: must be discarded by mt_apply
        echo "warning: some diff stderr" >&2
        exit "$(cat "$MT_TEST_DIFF_RC")" ;;
    *" apply "*)
        cat > "$MT_TEST_APPLY_IN"
        echo "$(cat "$MT_TEST_APPLY_SAYS")"
        exit "$(cat "$MT_TEST_APPLY_RC")" ;;
    *" rollout restart "*)
        echo "restarted"; exit 0 ;;
esac
echo "fake-kubectl: unscripted call: $*" >&2; exit 99
FAKE
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH"

PASS=0; FAIL=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1: expected [$2] got [$3]"; fi
}
scenario() {  # scenario <diff rc> <apply output line> [apply rc]
    : > "$MT_TEST_CALLS"; rm -f "$MT_TEST_DIFF_IN" "$MT_TEST_APPLY_IN"
    echo "$1" > "$MT_TEST_DIFF_RC"; echo "$2" > "$MT_TEST_APPLY_SAYS"; echo "${3:-0}" > "$MT_TEST_APPLY_RC"
    mt_reset_change_tracker
}
MANIFEST=$'apiVersion: v1\nkind: Secret\nmetadata:\n  name: s\ndata:\n  k: dg==\n'

# --- "configured" in apply output is NOT a change when diff says identical ---
scenario 0 "secret/s configured"
mt_apply kubectl apply -f <(printf '%s' "$MANIFEST") > "$TMP/out" 2>&1; rc=$?; out=$(cat "$TMP/out")
check "identical: rc" 0 "$rc"
case "$out" in *"some diff stderr"*|*"diff unavailable"*) check "identical: diff stderr never printed" no yes ;; *) check "identical: diff stderr never printed" no no ;; esac
check "identical: apply output shown" "secret/s configured" "$out"
check "identical: not flagged changed" false "$_mt_deploy_changed"
check "identical: diff ran before apply" "kubectl diff -f -
kubectl apply -f -" "$(cat "$MT_TEST_CALLS")"
check "identical: apply saw the same manifest" "$(cat "$MT_TEST_DIFF_IN")" "$(cat "$MT_TEST_APPLY_IN")"
check "identical: manifest content intact" "$(printf '%s' "$MANIFEST")" "$(cat "$MT_TEST_APPLY_IN")"
case "$out" in *CANARY*) check "identical: diff stdout never printed" no yes ;; *) check "identical: diff stdout never printed" no no ;; esac
out=$(mt_restart_if_changed deployment/x -n ns)
case "$out" in *"skipping restart"*) check "identical: restart skipped" y y ;; *) check "identical: restart skipped" y "n: $out" ;; esac

# --- diff says differs → changed, even if apply says "unchanged" (odd but possible) ---
scenario 1 "secret/s unchanged"
mt_apply kubectl apply -f <(printf '%s' "$MANIFEST") > "$TMP/out" 2>&1; rc=$?; out=$(cat "$TMP/out")
check "differs: rc" 0 "$rc"
check "differs: only apply output printed" "secret/s unchanged" "$out"
check "differs: flagged changed" true "$_mt_deploy_changed"
out=$(mt_restart_if_changed deployment/x -n ns)
case "$out" in *"Config changes detected"*) check "differs: restart issued" y y ;; *) check "differs: restart issued" y "n: $out" ;; esac

# --- object absent: diff exits 1 (created) ---
scenario 1 "secret/s created"
mt_apply kubectl apply -f <(printf '%s' "$MANIFEST") >/dev/null
check "created: flagged changed" true "$_mt_deploy_changed"

# --- diff unavailable (rc>1): fall back to the output grep, warn once ---
scenario 2 "secret/s configured"
mt_apply kubectl apply -f <(printf '%s' "$MANIFEST") > "$TMP/out" 2>&1; out=$(cat "$TMP/out")
check "fallback: changed via grep" true "$_mt_deploy_changed"
case "$out" in *"kubectl diff unavailable (rc=2: warning: some diff stderr)"*) check "fallback: warns with first stderr line" y y ;; *) check "fallback: warns with first stderr line" y "n: $out" ;; esac
case "$out" in *CANARY*) check "fallback: diff stdout never printed" no yes ;; *) check "fallback: diff stdout never printed" no no ;; esac
scenario 2 "secret/s unchanged"
mt_apply kubectl apply -f <(printf '%s' "$MANIFEST") >/dev/null 2>&1
check "fallback: unchanged stays unchanged" false "$_mt_deploy_changed"

# --- -n before -f is passed to both diff and apply; args after -f preserved ---
scenario 0 "secret/s configured"
mt_apply kubectl apply -n tn-x-files -f <(printf '%s' "$MANIFEST") --server-side=false >/dev/null
check "flags: diff/apply argv" "kubectl diff -n tn-x-files -f - --server-side=false
kubectl apply -n tn-x-files -f - --server-side=false" "$(cat "$MT_TEST_CALLS")"

# --- heredoc on stdin (-f -) ---
scenario 0 "configmap/c configured"
mt_apply kubectl apply -f - >/dev/null <<HD
apiVersion: v1
kind: ConfigMap
metadata:
  name: c
HD
check "stdin: manifest passed through" "apiVersion: v1
kind: ConfigMap
metadata:
  name: c" "$(cat "$MT_TEST_APPLY_IN")"
check "stdin: not flagged" false "$_mt_deploy_changed"

# --- plain file path ---
printf '%s' "$MANIFEST" > "$TMP/m.yaml"
scenario 1 "secret/s configured"
mt_apply kubectl apply -f "$TMP/m.yaml" >/dev/null
check "file: flagged" true "$_mt_deploy_changed"
check "file: content read" "$(printf '%s' "$MANIFEST")" "$(cat "$MT_TEST_APPLY_IN")"

# --- apply failure propagates its rc and output ---
scenario 1 "error: boom" 1
mt_apply kubectl apply -f "$TMP/m.yaml" > "$TMP/out"; rc=$?; out=$(cat "$TMP/out")
check "apply fail: rc" 1 "$rc"; check "apply fail: still flagged by diff" true "$_mt_deploy_changed"; check "apply fail: output" "error: boom" "$out"

# --- unreadable manifest path ---
scenario 0 "x"
mt_apply kubectl apply -f "$TMP/does-not-exist.yaml" >/dev/null 2>&1; rc=$?
check "missing file: rc" 2 "$rc"
check "missing file: kubectl never called" "" "$(cat "$MT_TEST_CALLS")"

# --- an inherited KUBECTL_EXTERNAL_DIFF is scrubbed before diff runs ---
scenario 0 "secret/s configured"
KUBECTL_EXTERNAL_DIFF="/tmp/evil" mt_apply kubectl apply -f "$TMP/m.yaml" > "$TMP/out" 2>&1
check "external-diff scrubbed: not flagged (diff ran, rc 0)" false "$_mt_deploy_changed"
case "$(cat "$TMP/out")" in *"diff unavailable"*) check "external-diff scrubbed: no fallback" no yes ;; *) check "external-diff scrubbed: no fallback" no no ;; esac

# --- accumulation across calls until reset ---
scenario 0 "a unchanged"
mt_apply kubectl apply -f "$TMP/m.yaml" >/dev/null
echo 1 > "$MT_TEST_DIFF_RC"; mt_apply kubectl apply -f "$TMP/m.yaml" >/dev/null
echo 0 > "$MT_TEST_DIFF_RC"; mt_apply kubectl apply -f "$TMP/m.yaml" >/dev/null
check "sticky: one change keeps the flag" true "$_mt_deploy_changed"
mt_reset_change_tracker; check "reset clears" false "$_mt_deploy_changed"

echo "mt-apply: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
