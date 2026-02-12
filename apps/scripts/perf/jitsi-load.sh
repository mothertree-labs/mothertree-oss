#!/usr/bin/env bash
set -euo pipefail

# Simple wrapper to kick off Jitsi load tests using an external harness.
# This script does not run in-cluster; it launches a container locally.
# Requirements: Docker installed locally.

if [[ -z "${JITSI_URL:-}" ]]; then
  echo "Set JITSI_URL (e.g., https://meet.example.com)" >&2
  exit 1
fi

PARTICIPANTS=${PARTICIPANTS:-10}
ROOM_NAME=${ROOM_NAME:-perf-room}

echo "Launching placeholder Jitsi load (participants=${PARTICIPANTS}, room=${ROOM_NAME})"
echo "NOTE: Integrate with jitsi-meet-torture or jitsi-load-tester as needed."

# Placeholder: pull a small image and echo; replace with real harness image/args.
docker run --rm alpine:3 sh -c "echo 'Jitsi load test would run against ${JITSI_URL}/${ROOM_NAME} with ${PARTICIPANTS} participants'"



