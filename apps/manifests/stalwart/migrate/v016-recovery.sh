#!/bin/sh
# Stalwart 0.15 → v1 migration, Job 2 native sidecar (#715): run v0.16.27 in
# recovery mode against the hop-1 scratch copy, so the converted 0.15 export
# can be applied with stalwart-cli. Recovery mode only opens the management
# API on 8080; it never accepts or sends mail.
#
# stalwart-migrate `run --final --yes` requires that no v0.16 node is
# running, so this container:
#   * stops for good when /work/hop1/stop-v016 appears (stop-v016.sh),
#   * never starts again once that file exists (a restart after an OOM or a
#     node blip must not bring recovery mode back during the final copy),
#   * then idles (sleep), because exiting would restart a native sidecar.
# No liveness probe; a startupProbe on 8080 gates the next init container.
#
# Runs in stalwartlabs/stalwart:v0.16.27. Env: STALWART_RECOVERY_ADMIN and
# the secrets config.v016.json / the export reference (DB password, S3 keys).
STOP=/work/hop1/stop-v016
idle() { while :; do sleep 3600; done; }

if [ -e "$STOP" ]; then
    idle
fi

STALWART_RECOVERY_MODE=1 /usr/local/bin/stalwart --config /work/hop1/config.v016.json \
    > /work/hop1/v016.log 2>&1 &
pid=$!

while [ ! -e "$STOP" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
        # Died on its own: leave it down (the cli steps fail and report).
        idle
    fi
    sleep 1
done
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
idle
