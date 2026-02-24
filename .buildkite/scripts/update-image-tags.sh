#!/usr/bin/env bash
# Update image-tags.env in config/platform after successful builds
# Reads tags from Buildkite metadata set by build-image.sh
#
# This script auto-commits updated tags to the private config submodule.
# Requires read-write deploy key for mt-config-platform.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAGS_FILE="${REPO_ROOT}/config/platform/image-tags.env"

# Check if config/platform submodule exists
if [ ! -d "${REPO_ROOT}/config/platform" ]; then
  echo "config/platform submodule not present, skipping tag update"
  exit 0
fi

echo "--- :label: Updating image tags"

# Read tags from Buildkite metadata (set by build-image.sh)
ADMIN_TAG=$(buildkite-agent meta-data get "ADMIN_PORTAL_IMAGE_TAG" 2>/dev/null || echo "")
ACCOUNT_TAG=$(buildkite-agent meta-data get "ACCOUNT_PORTAL_IMAGE_TAG" 2>/dev/null || echo "")
ROUNDCUBE_TAG=$(buildkite-agent meta-data get "ROUNDCUBE_IMAGE_TAG" 2>/dev/null || echo "")
PERF_TAG=$(buildkite-agent meta-data get "PERF_IMAGE_TAG" 2>/dev/null || echo "")

if [ -z "$ADMIN_TAG" ] && [ -z "$ACCOUNT_TAG" ] && [ -z "$ROUNDCUBE_TAG" ] && [ -z "$PERF_TAG" ]; then
  echo "No image tags found in metadata, skipping"
  exit 0
fi

# Read existing tags (if file exists) to preserve unchanged values
declare -A EXISTING_TAGS
if [ -f "$TAGS_FILE" ]; then
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    EXISTING_TAGS["$key"]="$value"
  done < "$TAGS_FILE"
fi

# Update tags (new value if set, otherwise preserve existing)
ADMIN_TAG="${ADMIN_TAG:-${EXISTING_TAGS[ADMIN_PORTAL_IMAGE_TAG]:-latest}}"
ACCOUNT_TAG="${ACCOUNT_TAG:-${EXISTING_TAGS[ACCOUNT_PORTAL_IMAGE_TAG]:-latest}}"
ROUNDCUBE_TAG="${ROUNDCUBE_TAG:-${EXISTING_TAGS[ROUNDCUBE_IMAGE_TAG]:-latest}}"
PERF_TAG="${PERF_TAG:-${EXISTING_TAGS[PERF_IMAGE_TAG]:-latest}}"

# Write updated tags file
cat > "$TAGS_FILE" <<EOF
# Auto-updated by CI after successful builds on main.
# These are git hash-based tags, not semantic versions.
# Format: sha-<7char> (from git commit hash)
ADMIN_PORTAL_IMAGE_TAG=${ADMIN_TAG}
ACCOUNT_PORTAL_IMAGE_TAG=${ACCOUNT_TAG}
ROUNDCUBE_IMAGE_TAG=${ROUNDCUBE_TAG}
PERF_IMAGE_TAG=${PERF_TAG}
EOF

echo "Updated image tags:"
cat "$TAGS_FILE"

# Auto-commit to config/platform submodule
cd "${REPO_ROOT}/config/platform"

if git diff --quiet image-tags.env 2>/dev/null; then
  echo "No tag changes to commit"
  exit 0
fi

git add image-tags.env
git commit -m "ci: update image tags to sha-${BUILDKITE_COMMIT:0:7}

Built from ${BUILDKITE_BUILD_URL:-commit ${BUILDKITE_COMMIT:-unknown}}"

git push
echo "Committed and pushed updated image tags"
