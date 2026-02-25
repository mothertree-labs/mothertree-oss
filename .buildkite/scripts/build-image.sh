#!/usr/bin/env bash
# Generic CI image build wrapper
# Routes to component-specific build scripts with semver tagging from VERSION files.
# Skips build if the image:version already exists in the registry (idempotent).
#
# Usage: .buildkite/scripts/build-image.sh <component>
#   Components: admin-portal, account-portal, roundcube, perf

set -euo pipefail

COMPONENT="${1:?Usage: build-image.sh <component>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Map component name to VERSION file path
case "${COMPONENT}" in
  admin-portal)    VERSION_FILE="${REPO_ROOT}/apps/admin-portal/VERSION" ;;
  account-portal)  VERSION_FILE="${REPO_ROOT}/apps/account-portal/VERSION" ;;
  roundcube)       VERSION_FILE="${REPO_ROOT}/apps/docker/roundcube/VERSION" ;;
  perf)            VERSION_FILE="${REPO_ROOT}/perf/VERSION" ;;
  *)
    echo "Unknown component: ${COMPONENT}"
    echo "Valid: admin-portal, account-portal, roundcube, perf"
    exit 1
    ;;
esac

# Read version from VERSION file
if [ ! -f "${VERSION_FILE}" ]; then
  echo "ERROR: VERSION file not found: ${VERSION_FILE}"
  exit 1
fi
TAG=$(tr -d '[:space:]' < "${VERSION_FILE}")
if [ -z "$TAG" ]; then
  echo "ERROR: VERSION file is empty: ${VERSION_FILE}"
  exit 1
fi

# Read container registry from project config
source "${REPO_ROOT}/scripts/lib/paths.sh"
_mt_resolve_project_conf
[[ -n "$MT_PROJECT_CONF" ]] && source "$MT_PROJECT_CONF"
REGISTRY="${CONTAINER_REGISTRY:?CONTAINER_REGISTRY must be set (via CI hook or config/platform/project.conf)}"

IMAGE_NAME="${REGISTRY}/mothertree-${COMPONENT}"

echo "--- :docker: Building ${COMPONENT} (${IMAGE_NAME}:${TAG})"

# Idempotency: skip build if image already exists in registry
if docker manifest inspect "${IMAGE_NAME}:${TAG}" >/dev/null 2>&1; then
  echo "Image ${IMAGE_NAME}:${TAG} already exists in registry, skipping build"
  # Still ensure :latest points to this version
  docker pull "${IMAGE_NAME}:${TAG}"
  docker tag "${IMAGE_NAME}:${TAG}" "${IMAGE_NAME}:latest"
  docker push "${IMAGE_NAME}:latest"
  echo "Updated ${IMAGE_NAME}:latest -> ${TAG}"
  exit 0
fi

case "${COMPONENT}" in
  admin-portal)
    IMAGE_TAG="${IMAGE_NAME}:${TAG}" PUSH=true \
      "${REPO_ROOT}/ci/scripts/build-admin-portal.sh"
    ;;
  account-portal)
    IMAGE_TAG="${IMAGE_NAME}:${TAG}" PUSH=true \
      "${REPO_ROOT}/ci/scripts/build-account-portal.sh"
    ;;
  roundcube)
    # Roundcube needs plugin submodules (both are public repos)
    git submodule update --init submodules/roundcubemail-plugins-kolab submodules/mailvelope_client
    IMAGE_TAG="${IMAGE_NAME}:${TAG}" PUSH=true \
      "${REPO_ROOT}/apps/scripts/build-roundcube-image.sh"
    ;;
  perf)
    IMAGE_TAG="${IMAGE_NAME}:${TAG}" PUSH=true PLATFORMS="linux/amd64" \
      "${REPO_ROOT}/apps/scripts/perf/build-k6-image.sh"
    ;;
esac

# Also tag as :latest
echo "--- Tagging ${IMAGE_NAME}:latest"
docker tag "${IMAGE_NAME}:${TAG}" "${IMAGE_NAME}:latest"
docker push "${IMAGE_NAME}:latest"

echo "Built and pushed ${IMAGE_NAME}:${TAG}"
