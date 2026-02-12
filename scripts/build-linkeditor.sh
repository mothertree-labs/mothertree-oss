#!/bin/bash
# Build the files_linkeditor Nextcloud app in an isolated Docker container
# This script works identically on local machine and CI
#
# Usage: ./scripts/build-linkeditor.sh

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
mt_deploy_start "build-linkeditor"

APP_DIR="$REPO_ROOT/submodules/files_linkeditor"

if [ ! -d "$APP_DIR" ]; then
    echo "Error: files_linkeditor submodule not found at $APP_DIR"
    echo "Run: git submodule update --init --recursive"
    exit 1
fi

echo "Building files_linkeditor..."

docker run --rm \
    -v "$APP_DIR:/app" \
    -w /app \
    node:20-alpine \
    sh -c "npm ci && npm run build"

echo "Build complete."
