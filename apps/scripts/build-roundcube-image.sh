#!/usr/bin/env bash
# Build the custom Roundcube Docker image with calendar and Mailvelope plugins
# Plugins are copied from git submodules (pre-patched)
#
# Usage: ./apps/scripts/build-roundcube-image.sh
#        PUSH=true ./apps/scripts/build-roundcube-image.sh  # Build and push to GHCR
#        IMAGE_TAG=ghcr.io/myorg/mothertree-roundcube:v1.0 PUSH=true ./apps/scripts/build-roundcube-image.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Parse nesting level for deploy notifications
NESTING_LEVEL=0
for arg in "$@"; do
  case "$arg" in
    --nesting-level=*) NESTING_LEVEL="${arg#*=}" ;;
  esac
done
_MT_NOTIFY_NESTING_LEVEL=$NESTING_LEVEL

source "${REPO_ROOT}/scripts/lib/notify.sh"
[[ -f "$REPO_ROOT/project.conf" ]] && source "$REPO_ROOT/project.conf"
mt_deploy_start "build-roundcube-image"

IMAGE_TAG=${IMAGE_TAG:-${CONTAINER_REGISTRY:-ghcr.io/YOUR_ORG}/mothertree-roundcube:latest}
PUSH=${PUSH:-false}
PLATFORMS=${PLATFORMS:-linux/amd64}
BUILDER_NAME=${BUILDER_NAME:-mt-roundcube-builder}

# Ensure submodules are initialized
if [ ! -d "$REPO_ROOT/submodules/roundcubemail-plugins-kolab/plugins/calendar" ]; then
    echo "Error: roundcubemail-plugins-kolab submodule not found or not initialized"
    echo "Run: git submodule update --init --recursive"
    exit 1
fi

if [ ! -f "$REPO_ROOT/submodules/mailvelope_client/mailvelope_client.php" ]; then
    echo "Error: mailvelope_client submodule not found or not initialized"
    echo "Run: git submodule update --init --recursive"
    exit 1
fi

echo "Building ${IMAGE_TAG} (platforms=${PLATFORMS}, push=${PUSH})"

# Decide if we need a docker-container driver (multi-platform) vs default.
NEEDS_MULTI=false
if [[ "${PLATFORMS}" == *","* ]]; then
    NEEDS_MULTI=true
fi

CURRENT_DRIVER="$(docker buildx inspect 2>/dev/null | awk -F': ' '/Driver:/ {print $2}' || true)"
if [[ "${NEEDS_MULTI}" == "true" ]]; then
    # Multi-platform builds require docker-container driver (or containerd image store).
    if [[ "${CURRENT_DRIVER}" != "docker-container" ]]; then
        if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
            echo "Creating docker-container buildx builder: ${BUILDER_NAME}"
            docker buildx create --name "${BUILDER_NAME}" --driver docker-container --bootstrap >/dev/null
        fi
        echo "Using builder: ${BUILDER_NAME} (docker-container)"
        docker buildx use "${BUILDER_NAME}" >/dev/null
        # Ensure QEMU emulators are ready
        docker buildx inspect --bootstrap >/dev/null
    fi
else
    # Single-arch builds can use default builder; create one if missing.
    if ! docker buildx inspect >/dev/null 2>&1; then
        docker buildx create --use >/dev/null
    fi
fi

# Build from repo root so COPY can access submodules
cd "$REPO_ROOT"

BUILD_CMD=(docker buildx build
    --platform "${PLATFORMS}"
    -f apps/docker/roundcube/Dockerfile
    -t "${IMAGE_TAG}"
    .
)

if [[ "${PUSH}" == "true" ]]; then
    "${BUILD_CMD[@]}" --push
    echo "Pushed ${IMAGE_TAG}"
else
    # --load only supports single-arch; we defaulted PLATFORMS to linux/amd64 above.
    "${BUILD_CMD[@]}" --load
    echo "Built (local) ${IMAGE_TAG}"
    echo "Push with: PUSH=true $0"
fi
