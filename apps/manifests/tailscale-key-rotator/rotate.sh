#!/bin/bash
# Entry point of the tailscale-key-rotator CronJob.
#
# All logic lives in /config/tailscale-keys.sh, which is scripts/lib/tailscale-keys.sh
# mounted verbatim by apps/deploy-tailscale-key-rotator.sh — the CronJob, the deploy
# scripts and scripts/check-tailscale-keys share one implementation.
#
# For every component in /config/components.conf: read the key the Secret holds,
# look it up on Headscale by its redacted prefix, and rotate (mint a tagged 90-day
# key, patch the Secret, restart the Deployment, prove the sidecar authenticated)
# when it is missing, single-use, untagged, expired or within 30 days of expiry.
# Any failure exits non-zero so KubeJobFailed fires.
set -euo pipefail

: "${HEADSCALE_URL:?HEADSCALE_URL not set}"
: "${HEADSCALE_API_KEY:?HEADSCALE_API_KEY not set}"

# shellcheck source=/dev/null
. /config/tailscale-keys.sh

mt_ts_run_components /config/components.conf
