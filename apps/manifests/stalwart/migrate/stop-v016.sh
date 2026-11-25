#!/bin/sh
# Stalwart 0.15 → v1 migration, Job 2 (#715): stop the v0.16.27 recovery
# sidecar and wait until its management port is closed, so the final
# stalwart-migrate run reads a store nothing else writes.
# Runs in stalwartlabs/stalwart:v0.16.27 (sh + curl).
set -eu
status() { { printf '%s' "$1" > /dev/termination-log; } 2>/dev/null || true; echo "$1"; }

touch /work/hop1/stop-v016
i=0
while curl -s -o /dev/null --max-time 2 http://127.0.0.1:8080/healthz/live; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        status "stop-v016: FAILED, 8080 still answering after 60s"
        exit 1
    fi
    sleep 1
done
status "stop-v016: OK stopped after ${i}s"
