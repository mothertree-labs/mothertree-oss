#!/usr/bin/env bash
set -euo pipefail

# Build the k6 runner image that bakes perf scripts into the container.
# Apple Silicon note: use buildx to build linux/amd64 (or multi-arch) so it runs on Linode nodes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/../../../project.conf" ]] && source "$SCRIPT_DIR/../../../project.conf"

IMAGE_TAG=${IMAGE_TAG:-${CONTAINER_REGISTRY:-ghcr.io/YOUR_ORG}/mothertree-perf:latest}
K6_IMAGE=${K6_IMAGE:-grafana/k6:0.49.0}
# When PUSH=true, build multi-arch and push; otherwise build amd64 locally and load into Docker.
PUSH=${PUSH:-false}
# Override to "linux/amd64,linux/arm64" if you want multi-arch without setting PUSH.
PLATFORMS=${PLATFORMS:-}
BUILDER_NAME=${BUILDER_NAME:-mt-perf-builder}

if [[ -z "${PLATFORMS}" ]]; then
  if [[ "${PUSH}" == "true" ]]; then
    PLATFORMS="linux/amd64,linux/arm64"
  else
    PLATFORMS="linux/amd64"
  fi
fi

echo "Building ${IMAGE_TAG} (base=${K6_IMAGE}, platforms=${PLATFORMS}, push=${PUSH})"

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

BUILD_CMD=(docker buildx build
  --platform "${PLATFORMS}"
  --build-arg "K6_IMAGE=${K6_IMAGE}"
  -f perf/docker/k6-runner.Dockerfile
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
  echo "Push with: docker push ${IMAGE_TAG}"
fi



