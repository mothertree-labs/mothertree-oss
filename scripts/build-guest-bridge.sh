#!/bin/bash
# Package the guest_bridge Nextcloud app for deployment
#
# Unlike files_linkeditor (which requires npm build), guest_bridge is pure PHP
# and just needs to be packaged. The deploy script handles including it in the
# custom apps ConfigMap.
#
# Usage: ./scripts/build-guest-bridge.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse nesting level for deploy notifications
NESTING_LEVEL=0
for arg in "$@"; do
  case "$arg" in
    --nesting-level=*) NESTING_LEVEL="${arg#*=}" ;;
  esac
done
_MT_NOTIFY_NESTING_LEVEL=$NESTING_LEVEL

source "${REPO_ROOT}/scripts/lib/notify.sh"
mt_deploy_start "build-guest-bridge"

APP_DIR="$REPO_ROOT/apps/nextcloud-guest-bridge"

if [ ! -d "$APP_DIR" ]; then
    echo "Error: guest_bridge app not found at $APP_DIR"
    exit 1
fi

# Validate required files exist
for required_file in appinfo/info.xml lib/AppInfo/Application.php lib/Listener/ShareCreatedListener.php; do
    if [ ! -f "$APP_DIR/$required_file" ]; then
        echo "Error: Required file missing: $required_file"
        exit 1
    fi
done

echo "guest_bridge app validated — pure PHP, no build step needed."
echo "The app will be packaged into the custom apps ConfigMap by deploy-nextcloud.sh."
