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

# If envsubst is available, template into a temp file; otherwise apply as-is
TMP_MANIFEST=$(mktemp)
if command -v envsubst >/dev/null 2>&1; then
  envsubst < "${MANIFEST_PATH}" > "${TMP_MANIFEST}"
else
  cp "${MANIFEST_PATH}" "${TMP_MANIFEST}"
fi

# Ensure namespace 'perf' exists before applying
KUBECONFIG="${KUBECONFIG_PATH}" kubectl get ns perf >/dev/null 2>&1 || \
  KUBECONFIG="${KUBECONFIG_PATH}" kubectl create ns perf >/dev/null 2>&1 || true

KUBECONFIG="${KUBECONFIG_PATH}" kubectl apply -f "${TMP_MANIFEST}"
rm -f "${TMP_MANIFEST}"


