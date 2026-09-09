#!/usr/bin/env bash
# Unit tests for scripts/verify-alerting: the metric parser and the delivery
# verdict loop, driven by a scripted fake `_snapshot` (no cluster). The script
# guards `main` behind a BASH_SOURCE check so it can be sourced here.
#
# Run: scripts/tests/test-verify-alerting.sh   (CI: ci/scripts/shell-unit-tests.sh)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../verify-alerting
source "${REPO_ROOT}/scripts/verify-alerting"
set +e   # the script enables -e for its own run; tests assert on non-zero returns
export ALERT_SELFTEST_POLL=0

PASS=0; FAIL=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "  ok   - $1"; else FAIL=$((FAIL + 1)); echo "  FAIL - $1 (expected [$2] got [$3])"; fi
}

# --- _metric_sum --------------------------------------------------------------
AM_TEXT='# HELP alertmanager_notifications_total ...
alertmanager_notifications_failed_total{integration="webhook",reason="clientError"} 0
alertmanager_notifications_failed_total{integration="webhook",reason="other"} 4
alertmanager_notifications_failed_total{integration="email",reason="other"} 9
alertmanager_notifications_total{integration="webhook"} 136
alertmanager_notifications_total{integration="email"} 7
matrix_alertmanager_receiver_send_success_total 3'
check "sums webhook failures across reasons only" 4 "$(_metric_sum "$AM_TEXT" 'alertmanager_notifications_failed_total{integration="webhook"')"
check "reads webhook total, not email" 136 "$(_metric_sum "$AM_TEXT" 'alertmanager_notifications_total{integration="webhook"')"
check "unlabelled counter" 3 "$(_metric_sum "$AM_TEXT" 'matrix_alertmanager_receiver_send_success_total')"
check "absent series -> NA" NA "$(_metric_sum "$AM_TEXT" 'matrix_alertmanager_receiver_send_failure_total')"
check "prefix without integration label sums all integrations (HELP line ignored)" 143 "$(_metric_sum "$AM_TEXT" 'alertmanager_notifications_total{')"

# --- verify_delivery with a scripted _snapshot ----------------------------------
# Each queue entry: "total failed ok fail" or "unreadable".
QUEUE=(); QPOS=0; FOREVER=""
_snapshot() {
    local step
    if [ -n "$FOREVER" ]; then step="$FOREVER"; else step="${QUEUE[$QPOS]:-unreadable}"; QPOS=$((QPOS + 1)); fi
    [ "$step" = "unreadable" ] && return 1
    # shellcheck disable=SC2034  # read by verify_delivery
    read -r WEBHOOK_TOTAL WEBHOOK_FAILED BRIDGE_OK BRIDGE_FAIL <<< "$step"
    return 0
}
run() { QUEUE=("$@"); QPOS=0; verify_delivery 100 4 10 0 3 >/dev/null 2>&1; echo $?; }
# baseline: total=100 failed=4 ok=10 fail=0, timeout 3s (poll 0 → iterations are fast; the
# timeout only matters for the "never moves" case, where SECONDS must advance)

check "delivered on first poll" 0 "$(run '101 4 11 0')"
check "delivered after a quiet poll" 0 "$(run '100 4 10 0' '101 4 11 0')"
check "webhook notified but bridge has not sent yet -> keep waiting, then ok" 0 "$(run '101 4 10 0' '101 4 11 0')"
check "AM webhook failures rose but bridge delivered -> 0 (other receiver failed; warning only)" 0 "$(run '101 5 11 0')"
check "AM webhook failures rose and bridge silent -> keep waiting, then bridge delivers -> 0" 0 "$(run '101 5 10 0' '102 5 11 0')"
check "bridge send failure moved -> 1" 1 "$(run '101 4 10 1')"
check "one unreadable then delivered -> 0" 0 "$(run unreadable '101 4 11 0')"
check "two unreadable then delivered -> 0 (counter resets on a good read)" 0 "$(run unreadable unreadable '101 4 11 0')"
check "three unreadable in a row -> 2" 2 "$(run unreadable unreadable unreadable)"
check "unreadable, good, unreadable, unreadable, good-delivered -> 0" 0 "$(run unreadable '100 4 10 0' unreadable unreadable '101 4 11 0')"

# AM failures rising with the bridge never delivering is a timeout (1), reported
# with the failure hint; drive it with FOREVER below.
FOREVER='101 5 10 0'
verify_delivery 100 4 10 0 2 >/dev/null 2>&1; rc=$?
FOREVER=""
check "AM webhook failures rose, bridge never delivered -> 1 after timeout" 1 "$rc"

# timeout: counters never move. With poll=0 the loop spins until SECONDS passes
# the timeout; FOREVER makes the fake answer the same baseline every time.
FOREVER='100 4 10 0'
verify_delivery 100 4 10 0 2 >/dev/null 2>&1; rc=$?
FOREVER=""
check "counters never move -> 1 after timeout" 1 "$rc"

echo ""
echo "test-verify-alerting.sh: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
