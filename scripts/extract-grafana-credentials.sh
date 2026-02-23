#!/bin/bash

# Extract Grafana admin credentials from Kubernetes secret
# Usage: ./scripts/extract-grafana-credentials.sh [--env <dev|prod>]

set -e

ENV="prod"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--env <dev|prod>]" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KUBECONFIG_FILE="${SCRIPT_DIR}/../kubeconfig.${ENV}.yaml"

if [[ ! -f "$KUBECONFIG_FILE" ]]; then
  echo "Error: kubeconfig not found at $KUBECONFIG_FILE" >&2
  exit 1
fi

export KUBECONFIG="$KUBECONFIG_FILE"

kubectl get secret kube-prometheus-stack-grafana -n infra-monitoring -o jsonpath='{.data.admin-password}' | base64 -d
echo
