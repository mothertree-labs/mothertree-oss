#!/bin/bash
# Check for available Nextcloud app updates against pinned versions.
#
# Reads apps/manifests/nextcloud/app-versions.json and queries the Nextcloud
# app store API to find newer compatible versions. Release selection lives in
# scripts/lib/nextcloud-app-versions.py so that the report and the writeback
# can never disagree about which release is "latest" — they did once, which is
# how a release candidate reached the manifest.
#
# Prereleases (6.6.0-rc.2) and nightlies are skipped unless --allow-prerelease.
#
# Usage:
#   ./scripts/check-nextcloud-app-versions.sh                      # Show available updates
#   ./scripts/check-nextcloud-app-versions.sh --update             # Update app-versions.json in place
#   ./scripts/check-nextcloud-app-versions.sh --allow-prerelease   # Include RCs/betas (manual use)
#
# Exit: 0 = up to date, 1 = error, 2 = updates available (0 in --update mode).

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MANIFEST="$REPO_ROOT/apps/manifests/nextcloud/app-versions.json"
SELECTOR="$REPO_ROOT/scripts/lib/nextcloud-app-versions.py"
UPDATE_MODE=false
SELECT_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --update)
            UPDATE_MODE=true
            SELECT_ARGS+=("--update")
            ;;
        --allow-prerelease)
            SELECT_ARGS+=("--allow-prerelease")
            ;;
        *)
            echo "Error: unknown argument '$arg'" >&2
            exit 1
            ;;
    esac
done

[ -f "$MANIFEST" ] || { echo "Error: $MANIFEST not found" >&2; exit 1; }
[ -f "$SELECTOR" ] || { echo "Error: $SELECTOR not found" >&2; exit 1; }

PLATFORM_VERSION=$(python3 - "$MANIFEST" <<'PYEOF'
import json, sys
print(json.load(open(sys.argv[1]))['platform_version'])
PYEOF
)
: "${PLATFORM_VERSION:?platform_version missing from $MANIFEST}"

echo "Checking Nextcloud app store for platform version $PLATFORM_VERSION..."
echo ""

API_URL="https://apps.nextcloud.com/api/v1/platform/${PLATFORM_VERSION}/apps.json"
API_CACHE=$(mktemp)
trap 'rm -f "$API_CACHE"' EXIT

# Bounded: an unbounded fetch inside the workflow's concurrency group would
# wedge every subsequent scheduled run and manual dispatch, not just this one.
curl -sf --max-time 60 "$API_URL" > "$API_CACHE" || {
    echo "Error: Could not fetch app store API at $API_URL" >&2
    exit 1
}

set +e
python3 "$SELECTOR" "$MANIFEST" "$API_CACHE" "${SELECT_ARGS[@]+"${SELECT_ARGS[@]}"}"
RESULT_EXIT=$?
set -e

if [ "$RESULT_EXIT" -eq 2 ] && [ "$UPDATE_MODE" = true ]; then
    # The update we were asked to perform succeeded. Exit 2 means "updates
    # pending" — that's the check-mode contract, not an error here. Reporting
    # success keeps the CI step (which runs under `bash -e`) from failing.
    exit 0
elif [ "$RESULT_EXIT" -eq 2 ]; then
    echo ""
    echo "Run with --update to update the manifest file"
fi

exit "${RESULT_EXIT}"
