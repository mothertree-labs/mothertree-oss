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

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."

# A `|` inside `<( ... )` is the generator's own pipeline and is fine; only a
# pipe at paren depth 0 on the mt_apply line is a problem. `||` is an error
# handler, not a pipe. Comment lines are skipped.
offenders=$(grep -rnE --include='*.sh' --include='deploy_infra' --include='create_env' \
      'mt_apply[[:space:]]' apps/ scripts/ ci/ 2>/dev/null \
    | grep -v '^scripts/lib/tests/' \
    | awk -F: '
        {
            line = $0; sub(/^[^:]+:[0-9]+:/, "", line)
            if (line ~ /^[[:space:]]*#/) next
            depth = 0; bad = 0; n = length(line)
            for (i = 1; i <= n; i++) {
                c = substr(line, i, 1)
                if (c == "(") depth++
                else if (c == ")") { if (depth > 0) depth-- }
                else if (c == "|" && depth == 0) {
                    if (substr(line, i - 1, 1) != "|" && substr(line, i + 1, 1) != "|") bad = 1
                }
            }
            if (bad) print $0
        }')

if [ -n "$offenders" ]; then
    echo "FAIL: mt_apply used in a pipeline — the change flag is lost in a subshell (#644):"
    printf '%s\n' "$offenders"
    echo "Use: mt_apply kubectl apply -f <(generator)   or   -f - <<EOF"
    exit 1
fi
echo "mt-apply-callsites: no pipelines into or out of mt_apply"
