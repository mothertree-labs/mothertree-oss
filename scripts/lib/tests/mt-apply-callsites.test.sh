#!/usr/bin/env bash
# Lint: no deploy script may pipe into or out of mt_apply (#644).
#
# bash runs every member of a pipeline in a subshell, so
#   gen | mt_apply kubectl apply -f -        # flag set in a throwaway shell
#   mt_apply kubectl apply -f x | tee log    # same
# both leave _mt_deploy_changed untouched in the caller and the following
# mt_restart_if_changed silently never fires. 30 infra-tier sites had this
# shape (pgbouncer, postfix, tailscale-router, keycloak theme, ...). Use
# `-f <(gen)`, `-f - <<EOF`, or a file. Invoked by ci/scripts/shell-unit-tests.sh.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || { echo "FAIL: cannot cd to repo root"; exit 1; }

files=$(grep -rlE --include='*.sh' --include='deploy_infra' --include='create_env' \
    'mt_apply[[:space:]]' apps/ scripts/ ci/ 2>/dev/null | grep -v '^scripts/lib/tests/')
if [ -z "$files" ]; then
    echo "FAIL: no mt_apply call sites found — is the lint looking at the right tree?"
    exit 1
fi

# Backslash-continued lines are joined into one logical line first, so a pipe
# on a continuation line counts. A `|` inside `<( ... )` is the generator's
# own pipeline and is fine; only a pipe at paren depth 0 on a logical line
# that calls mt_apply is a problem. `||` is an error handler, not a pipe.
# Comment lines are skipped.
# shellcheck disable=SC2086
offenders=$(awk '
    function scan(line, start,    depth, bad, n, i, c, prev, nxt) {
        if (line ~ /^[[:space:]]*#/ || line !~ /mt_apply[[:space:]]/) return
        depth = 0; bad = 0; n = length(line)
        for (i = 1; i <= n; i++) {
            c = substr(line, i, 1)
            if (c == "(") depth++
            else if (c == ")") { if (depth > 0) depth-- }
            else if (c == "|" && depth == 0) {
                prev = (i > 1) ? substr(line, i - 1, 1) : ""
                nxt = (i < n) ? substr(line, i + 1, 1) : ""
                if (prev != "|" && nxt != "|") bad = 1
            }
        }
        if (bad) print FILENAME ":" start ":" line
    }
    FNR == 1 { logical = ""; first = 0 }
    {
        if (logical == "") first = FNR
        if ($0 ~ /\\$/) { logical = logical substr($0, 1, length($0) - 1) " "; next }
        logical = logical $0
        scan(logical, first)
        logical = ""
    }
    END { if (logical != "") scan(logical, first) }
' $files) || { echo "FAIL: the awk scanner itself failed (rc $?) — refusing to pass vacuously"; exit 1; }

if [ -n "$offenders" ]; then
    echo "FAIL: mt_apply used in a pipeline — the change flag is lost in a subshell (#644):"
    printf '%s\n' "$offenders"
    echo "Use: mt_apply kubectl apply -f <(generator)   or   -f - <<EOF"
    exit 1
fi
echo "mt-apply-callsites: no pipelines into or out of mt_apply ($(printf '%s\n' "$files" | wc -l | tr -d ' ') files scanned)"
