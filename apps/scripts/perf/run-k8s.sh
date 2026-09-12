#!/usr/bin/env bash
set -euo pipefail

# Usage: ./apps/scripts/perf/run-k8s.sh --env dev|prod <manifest-name> [--yes]
# Example: ./apps/scripts/perf/run-k8s.sh --env dev k6-docs-load.yaml

ENVIRONMENT=dev
CONFIRM=no

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 --env dev|prod <manifest-name> [--yes]" >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENVIRONMENT="$2"; shift 2 ;;
    --yes)
      CONFIRM=yes; shift ;;
    *)
      break ;;
  esac
done

MANIFEST_NAME="${1:-}"; shift || true

if [[ -z "${MANIFEST_NAME}" ]]; then
  echo "Missing <manifest-name>." >&2
  exit 1
fi

if [[ "${ENVIRONMENT}" == "prod" && "${CONFIRM}" != "yes" ]]; then
  echo "Refusing to run against prod without --yes" >&2
  exit 2
fi

MANIFEST_PATH="apps/manifests/perf/${ENVIRONMENT}/${MANIFEST_NAME}"
if [[ ! -f "${MANIFEST_PATH}" ]]; then
  echo "Manifest not found: ${MANIFEST_PATH}" >&2
  exit 3
fi

echo "Applying ${MANIFEST_PATH} (env=${ENVIRONMENT})"

# Load env for templating (e.g., ${POSTGRES_DSN}, ${REDIS_ADDR}, ${TURN_*})
ENV_FILE="perf/env/${ENVIRONMENT}.env"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

# Choose kubeconfig per environment
KUBECONFIG_PATH="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/kubeconfig.${ENVIRONMENT}.yaml"

# The k6 manifests reference ${PERF_IMAGE}; resolve it the same way the deploy
# scripts do. Without this they carried a hardcoded `ghcr.io/YOUR_ORG/...`
# literal that nothing substituted, so kubelet reported InvalidImageName and the
# Jobs could never pull (#665).
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# shellcheck source=../../../scripts/lib/image-tags.sh
source "${REPO_ROOT}/scripts/lib/image-tags.sh"
_mt_load_image_tags
# A non-empty check would be dead code here: image-tags.sh uses ${PERF_IMAGE:-...}
# so an empty value is replaced by the default. The reachable failure is an
# unresolved placeholder registry, which would otherwise reach kubectl as an
# unpullable reference -- assert that instead.
case "${PERF_IMAGE:-}" in
  *YOUR_ORG*|"") echo "CONTAINER_REGISTRY is unset: perf image resolved to '${PERF_IMAGE:-<empty>}'." >&2
                 echo "Set CONTAINER_REGISTRY or provide config/platform/project.conf." >&2
                 exit 5 ;;
esac

# If envsubst is available, template into a temp file; otherwise apply as-is
TMP_MANIFEST=$(mktemp)
trap 'rm -f "${TMP_MANIFEST:-}"' EXIT
if command -v envsubst >/dev/null 2>&1; then
  envsubst < "${MANIFEST_PATH}" > "${TMP_MANIFEST}"
else
  echo "envsubst not found: the manifest's \${PERF_IMAGE} (and \${POSTGRES_DSN} etc.) would be applied literally." >&2
  exit 4
fi

# Ensure namespace 'perf' exists before applying
KUBECONFIG="${KUBECONFIG_PATH}" kubectl get ns perf >/dev/null 2>&1 || \
  KUBECONFIG="${KUBECONFIG_PATH}" kubectl create ns perf >/dev/null 2>&1 || true

KUBECONFIG="${KUBECONFIG_PATH}" kubectl apply -f "${TMP_MANIFEST}"
rm -f "${TMP_MANIFEST}"


