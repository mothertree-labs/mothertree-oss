#!/usr/bin/env bash
set -euo pipefail

# Usage: ./apps/scripts/perf/run-local.sh --env dev|prod [--users /path/to/users.csv] <suite> <scenario> [--yes]
# Example: ./apps/scripts/perf/run-local.sh --env dev --users perf/users/example.csv docs load

ENVIRONMENT=dev
CONFIRM=no
USERS_ARG=""

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 --env dev|prod [--users /path/to/users.csv] <suite> <scenario> [--yes]" >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENVIRONMENT="$2"; shift 2 ;;
    --users)
      USERS_ARG="$2"; shift 2 ;;
    --yes)
      CONFIRM=yes; shift ;;
    *)
      break ;;
  esac
done

SUITE="${1:-}"; shift || true
SCENARIO="${1:-}"; shift || true

if [[ -z "${SUITE}" || -z "${SCENARIO}" ]]; then
  echo "Missing <suite> and/or <scenario>." >&2
  exit 1
fi

if [[ "${ENVIRONMENT}" == "prod" && "${CONFIRM}" != "yes" ]]; then
  echo "Refusing to run against prod without --yes" >&2
  exit 2
fi

ENV_FILE="perf/env/${ENVIRONMENT}.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Env file not found: ${ENV_FILE}" >&2
  exit 3
fi
# Export variables from env file so k6 sees them
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

PROM_ARG=()
if [[ -n "${PROM_RW_URL:-}" ]]; then
  PROM_ARG=("--out" "experimental-prometheus-rw=${PROM_RW_URL}")
fi

SCRIPT_PATH="perf/k6/${SUITE}/${SCENARIO}.js"
if [[ ! -f "${SCRIPT_PATH}" ]]; then
  echo "k6 script not found: ${SCRIPT_PATH}" >&2
  exit 4
fi

echo "Running: k6 run ${SCRIPT_PATH} (env=${ENVIRONMENT})"
if (( ${#PROM_ARG[@]} )); then
  USERS_CSV_PATH="${USERS_ARG}" ENV="${ENVIRONMENT}" k6 run "${PROM_ARG[@]}" "${SCRIPT_PATH}"
else
  USERS_CSV_PATH="${USERS_ARG}" ENV="${ENVIRONMENT}" k6 run "${SCRIPT_PATH}"
fi



