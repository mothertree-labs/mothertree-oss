#!/bin/bash
# Check for available Nextcloud app updates against pinned versions.
#
# Reads apps/manifests/nextcloud/app-versions.json and queries the Nextcloud
# app store API to find newer compatible versions.
#
# Usage:
#   ./scripts/check-nextcloud-app-versions.sh           # Show available updates
#   ./scripts/check-nextcloud-app-versions.sh --update   # Update app-versions.json in place

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MANIFEST="$REPO_ROOT/apps/manifests/nextcloud/app-versions.json"
UPDATE_MODE=false

if [ "${1:-}" = "--update" ]; then
    UPDATE_MODE=true
fi

if [ ! -f "$MANIFEST" ]; then
    echo "Error: $MANIFEST not found" >&2
    exit 1
fi

PLATFORM_VERSION=$(python3 -c "import json; print(json.load(open('$MANIFEST'))['platform_version'])")

echo "Checking Nextcloud app store for platform version $PLATFORM_VERSION..."
echo ""

API_URL="https://apps.nextcloud.com/api/v1/platform/${PLATFORM_VERSION}/apps.json"
API_CACHE=$(mktemp)
trap 'rm -f "$API_CACHE"' EXIT

curl -sf "$API_URL" > "$API_CACHE" || {
    echo "Error: Could not fetch app store API at $API_URL" >&2
    exit 1
}

# Compare pinned versions against latest compatible versions
set +e
RESULT=$(python3 - "$MANIFEST" "$API_CACHE" <<'PYEOF'
import json, sys

manifest_path, api_path = sys.argv[1], sys.argv[2]

with open(manifest_path) as f:
    manifest = json.load(f)
with open(api_path) as f:
    apps = json.load(f)

app_index = {a['id']: a for a in apps}

updates = []
for app_id, pinned_version in sorted(manifest['apps'].items()):
    if app_id not in app_index:
        print(f'  {app_id}: {pinned_version} (not found in app store)')
        continue
    releases = app_index[app_id].get('releases', [])
    if not releases:
        print(f'  {app_id}: {pinned_version} (no releases)')
        continue
    latest_version = releases[0]['version']
    if latest_version != pinned_version:
        print(f'  {app_id}: {pinned_version} -> {latest_version}')
        updates.append((app_id, pinned_version, latest_version))
    else:
        print(f'  {app_id}: {pinned_version} (up to date)')

if updates:
    print(f'\n{len(updates)} update(s) available')
    sys.exit(2)
else:
    print('\nAll apps are up to date')
    sys.exit(0)
PYEOF
)
RESULT_EXIT=$?
set -e

echo "$RESULT"

if [ "$RESULT_EXIT" -eq 2 ] && [ "$UPDATE_MODE" = true ]; then
    echo ""
    echo "Updating $MANIFEST..."
    python3 - "$MANIFEST" "$API_CACHE" <<'PYEOF'
import json, sys

manifest_path, api_path = sys.argv[1], sys.argv[2]

with open(manifest_path) as f:
    manifest = json.load(f)
with open(api_path) as f:
    apps = json.load(f)

app_index = {a['id']: a for a in apps}

for app_id in manifest['apps']:
    if app_id in app_index:
        releases = app_index[app_id].get('releases', [])
        if releases:
            manifest['apps'][app_id] = releases[0]['version']

with open(manifest_path, 'w') as f:
    json.dump(manifest, f, indent=2)
    f.write('\n')

print('Manifest updated successfully')
PYEOF
elif [ "$RESULT_EXIT" -eq 2 ]; then
    echo ""
    echo "Run with --update to update the manifest file"
fi

exit "${RESULT_EXIT}"
