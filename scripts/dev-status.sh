#!/usr/bin/env bash
# dev-status.sh — Is the on-demand dev cluster running, and how close to reap?
#
# Reads /var/log/dev-reaper.log on the CI VM and parses the most recent reaper
# invocation. Up to 15 minutes stale (reaper runs `*/15`).
#
# Usage: ./scripts/dev-status.sh
# Env:   CI_HOST     (default: root@100.64.0.19, the Tailscale address)
#        REAPER_LOG  (default: /var/log/dev-reaper.log)

set -euo pipefail

CI_HOST="${CI_HOST:-root@100.64.0.19}"
LOG="${REAPER_LOG:-/var/log/dev-reaper.log}"

# Grab everything from the last "no cluster" / "found cluster" marker to EOF —
# that's the most recent invocation (each cron tick starts with one of those).
last_run=$(ssh -o ConnectTimeout=10 "$CI_HOST" \
    "awk '/no .* cluster; nothing to do|found cluster id=/{p=NR} {a[NR]=\$0} END{for(i=p;i<=NR;i++)print a[i]}' '$LOG'" \
    2>/dev/null) || {
    echo "ERROR: could not reach $CI_HOST or read $LOG" >&2
    exit 1
}

if [ -z "$last_run" ]; then
    echo "ERROR: no reaper runs found in $LOG (reaper may not have run yet)" >&2
    exit 1
fi

run_ts=$(printf '%s\n' "$last_run" | head -1 | sed -n 's/.*\[dev-reaper \([^]]*\)\].*/\1/p')

# Human-readable "(X ago)" suffix for the Last-check line. Portable across
# macOS (BSD date) and Linux (GNU date) — BSD wants %z as +0000, GNU accepts
# the ISO 8601 +00:00, so strip the colon before parsing.
fmt_ago() {
    local ts="$1" epoch now delta
    local cleaned
    cleaned=$(printf '%s' "$ts" | sed 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')
    epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$cleaned" +%s 2>/dev/null \
        || date -d "$ts" +%s 2>/dev/null) || { echo ""; return; }
    now=$(date +%s)
    delta=$((now - epoch))
    if   [ "$delta" -lt 90 ];   then echo "(just now)"
    elif [ "$delta" -lt 3600 ]; then echo "($((delta/60))m ago)"
    else echo "($((delta/3600))h $((delta%3600/60))m ago)"
    fi
}
run_ago=$(fmt_ago "$run_ts")

if printf '%s\n' "$last_run" | grep -q "no .* cluster; nothing to do"; then
    echo "Dev cluster:  NOT RUNNING"
    echo "Last check:   $run_ts $run_ago"
    exit 0
fi

cluster_id=$(printf '%s\n' "$last_run" | grep -oE 'cluster id=[0-9]+' | head -1 | cut -d= -f2)
idle_s=$(printf '%s\n' "$last_run" | grep -oE 'idle=[0-9]+s' | head -1 | grep -oE '[0-9]+')

# Threshold is logged in "still active (idle Xs < Ys)" or "idle for Xs ≥ Ys".
threshold_s=$(printf '%s\n' "$last_run" | grep -oE '(< |≥ )[0-9]+s' | head -1 | grep -oE '[0-9]+')
threshold_s="${threshold_s:-7200}"
idle_s="${idle_s:-0}"
remain_s=$((threshold_s - idle_s))

echo "Dev cluster:  RUNNING (id=$cluster_id)"
echo "Last check:   $run_ts $run_ago"
printf "Idle:         %ss (%sm)\n" "$idle_s" "$((idle_s/60))"

if printf '%s\n' "$last_run" | grep -qE "ci-lease-pool[12] is held"; then
    pool=$(printf '%s\n' "$last_run" | grep -oE 'ci-lease-pool[12]' | head -1)
    echo "Lease:        HELD ($pool) — pipeline in flight"
    echo "Status:       ACTIVE — destroy blocked by lease"
elif printf '%s\n' "$last_run" | grep -q "no pool leases held"; then
    echo "Lease:        clear"
    if [ "$remain_s" -le 0 ]; then
        echo "Status:       IDLE PAST THRESHOLD — next reaper tick (≤15m) will destroy"
    else
        echo "Status:       IDLE"
        printf "Time to reap: %ss (%sm)\n" "$remain_s" "$((remain_s/60))"
    fi
elif printf '%s\n' "$last_run" | grep -q "still active"; then
    # idle < threshold; reaper exits before lease check.
    echo "Lease:        (not checked yet — still inside idle window)"
    echo "Status:       ACTIVE"
    printf "Time to reap: %ss (%sm), assuming no further CI activity\n" "$remain_s" "$((remain_s/60))"
elif printf '%s\n' "$last_run" | grep -q "destroying"; then
    echo "Status:       DESTROY IN PROGRESS"
else
    echo "Status:       unknown (log entry incomplete)"
fi
