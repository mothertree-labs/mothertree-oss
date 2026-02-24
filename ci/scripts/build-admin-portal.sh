#!/usr/bin/env bash
# Build the Admin Portal Docker image
# Extracted from scripts/create_env for standalone CI use
#
# Usage: ./ci/scripts/build-admin-portal.sh
#        IMAGE_TAG=ghcr.io/org/mothertree-admin-portal:sha-abc1234 PUSH=true ./ci/scripts/build-admin-portal.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "${REPO_ROOT}/scripts/lib/paths.sh"
_mt_resolve_project_conf
[[ -n "$MT_PROJECT_CONF" ]] && source "$MT_PROJECT_CONF"

IMAGE_TAG=${IMAGE_TAG:-${CONTAINER_REGISTRY:-ghcr.io/YOUR_ORG}/mothertree-admin-portal:latest}
PUSH=${PUSH:-false}
PLATFORMS=${PLATFORMS:-linux/amd64}

ADMIN_PORTAL_SRC="$REPO_ROOT/apps/admin-portal"

echo "Building ${IMAGE_TAG} (platforms=${PLATFORMS}, push=${PUSH})"

# Set up buildx builder if needed
if ! docker buildx inspect >/dev/null 2>&1; then
  docker buildx create --use >/dev/null
fi

cd "$ADMIN_PORTAL_SRC"

# Install npm dependencies if needed (for Tailwind CSS build inside Docker)
if [ ! -d "node_modules" ]; then
  echo "Installing npm dependencies..."
  npm install
fi

BUILD_CMD=(docker buildx build
  --platform "${PLATFORMS}"
  -t "${IMAGE_TAG}"
  .
)

if [[ "${PUSH}" == "true" ]]; then
  "${BUILD_CMD[@]}" --push
  echo "Pushed ${IMAGE_TAG}"
else
  "${BUILD_CMD[@]}" --load
  echo "Built (local) ${IMAGE_TAG}"
fi
