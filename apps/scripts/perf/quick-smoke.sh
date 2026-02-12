#!/usr/bin/env bash
set -euo pipefail

# Quick end-to-end smoke: local docs smoke + submit k8s job (dev)

./apps/scripts/perf/run-local.sh --env dev docs smoke

scripts/create_env dev
KUBECONFIG="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}/kubeconfig.dev.yaml" kubectl create namespace perf >/dev/null 2>&1 || true
./apps/scripts/perf/run-k8s.sh --env dev k6-docs-smoke.yaml

echo "Submitted k8s smoke job to namespace 'perf'. Check Grafana for k6 metrics."



