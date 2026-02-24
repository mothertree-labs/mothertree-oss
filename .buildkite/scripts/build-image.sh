#!/usr/bin/env bash
# Generic CI image build wrapper
# Routes to component-specific build scripts with SHA-based tagging
#
# Usage: .buildkite/scripts/build-image.sh <component>
#   Components: admin-portal, account-portal, roundcube, perf

set -euo pipefail

COMPONENT="${1:?Usage: build-image.sh <component>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Compute immutable SHA-based tag
COMMIT="${BUILDKITE_COMMIT:-$(git rev-parse HEAD)}"
TAG="sha-${COMMIT:0:7}"

# Read container registry from project config
source "${REPO_ROOT}/scripts/lib/paths.sh"
_mt_resolve_project_conf
[[ -n "$MT_PROJECT_CONF" ]] && source "$MT_PROJECT_CONF"
REGISTRY="${CONTAINER_REGISTRY:-ghcr.io/YOUR_ORG}"

IMAGE_NAME="${REGISTRY}/mothertree-${COMPONENT}"

echo "--- :docker: Building ${COMPONENT} (${IMAGE_NAME}:${TAG})"

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
    IMAGE_TAG="${IMAGE_NAME}:${TAG}" PUSH=true \
      "${REPO_ROOT}/apps/scripts/build-roundcube-image.sh"
    ;;
  perf)
    cd "${REPO_ROOT}/apps"
    IMAGE_TAG="${IMAGE_NAME}:${TAG}" PUSH=true \
      "${REPO_ROOT}/apps/scripts/perf/build-k6-image.sh"
    ;;
  *)
    echo "Unknown component: ${COMPONENT}"
    echo "Valid: admin-portal, account-portal, roundcube, perf"
    exit 1
    ;;
esac

# Also tag as :latest for backward compatibility
echo "--- Tagging ${IMAGE_NAME}:latest"
docker buildx imagetools create \
  --tag "${IMAGE_NAME}:latest" \
  "${IMAGE_NAME}:${TAG}" 2>/dev/null || {
  # Fallback: pull, retag, push (when imagetools not available)
  docker pull "${IMAGE_NAME}:${TAG}" 2>/dev/null || true
  docker tag "${IMAGE_NAME}:${TAG}" "${IMAGE_NAME}:latest" 2>/dev/null || true
  docker push "${IMAGE_NAME}:latest" 2>/dev/null || true
}

# Store tag in Buildkite metadata for the update-image-tags step
METADATA_KEY=$(echo "${COMPONENT}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')_IMAGE_TAG
buildkite-agent meta-data set "${METADATA_KEY}" "${TAG}" 2>/dev/null || true

echo "Built and pushed ${IMAGE_NAME}:${TAG}"
