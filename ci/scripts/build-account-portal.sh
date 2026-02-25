#!/usr/bin/env bash
# Build the Account Portal Docker image
# Extracted from scripts/create_env for standalone CI use
#
# Usage: ./ci/scripts/build-account-portal.sh
#        IMAGE_TAG=ghcr.io/org/mothertree-account-portal:sha-abc1234 PUSH=true ./ci/scripts/build-account-portal.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "${REPO_ROOT}/scripts/lib/paths.sh"
_mt_resolve_project_conf
[[ -n "$MT_PROJECT_CONF" ]] && source "$MT_PROJECT_CONF"

IMAGE_TAG=${IMAGE_TAG:-${CONTAINER_REGISTRY:-ghcr.io/YOUR_ORG}/mothertree-account-portal:latest}
PUSH=${PUSH:-false}
PLATFORMS=${PLATFORMS:-linux/amd64}

ACCOUNT_PORTAL_SRC="$REPO_ROOT/apps/account-portal"

echo "Building ${IMAGE_TAG} (platforms=${PLATFORMS}, push=${PUSH})"

# Set up buildx builder if needed
if ! docker buildx inspect >/dev/null 2>&1; then
  docker buildx create --use >/dev/null
fi

cd "$ACCOUNT_PORTAL_SRC"

# Install npm dependencies if needed (for Tailwind CSS build inside Docker)
if [ ! -d "node_modules" ]; then
  echo "Installing npm dependencies..."
  npm install
fi

if [[ "${PUSH}" == "true" ]]; then
  docker build -t "${IMAGE_TAG}" .
  docker push "${IMAGE_TAG}"
  echo "Pushed ${IMAGE_TAG}"
else
  docker build -t "${IMAGE_TAG}" .
  echo "Built (local) ${IMAGE_TAG}"
fi
