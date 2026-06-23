#!/bin/bash

# Deploy Ollama inference engine to the shared infra-llm namespace
# This is a shared-infra service (not per-tenant), so -t/--tenant is not required.
#
# Called by: deploy_infra
# Can also be run standalone.
#
# Usage:
#   ./apps/deploy-llm.sh -e <env>
#
# Examples:
#   ./apps/deploy-llm.sh -e dev
#   ./apps/deploy-llm.sh -e prod

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  echo "Usage: $0 -e <env>"
  echo ""
  echo "Deploy Ollama inference engine to the shared infra-llm namespace."
  echo ""
  echo "Options:"
  echo "  -e <env>       Environment (e.g., dev, prod)"
  echo "  -h, --help     Show this help"
}

mt_parse_args "$@"
mt_require_env

source "${REPO_ROOT}/scripts/lib/paths.sh"
_mt_resolve_infra_config "$MT_ENV"

if [ -z "$MT_INFRA_CONFIG" ] || [ ! -f "$MT_INFRA_CONFIG" ]; then
  print_error "Infrastructure config not found for env: $MT_ENV"
  exit 1
fi

LLM_MODEL=$(yq '.llm.model // "llama3.2:1b"' "$MT_INFRA_CONFIG")

print_status "Deploying Ollama inference engine to env=${MT_ENV}, model=${LLM_MODEL}"

MANIFESTS_DIR="$REPO_ROOT/apps/manifests/llm"
mt_require_commands kubectl yq

print_status "Applying namespace..."
kubectl apply -f "${MANIFESTS_DIR}/namespace.yaml"

print_status "Deploying Ollama..."
export LLM_MODEL
mt_apply kubectl apply -f <(envsubst < "${MANIFESTS_DIR}/ollama.yaml.tpl")

print_status "Waiting for Ollama to be ready..."
kubectl rollout status deployment/ollama -n infra-llm --timeout=300s || {
  print_warning "Ollama rollout not ready within timeout — dumping pod diagnostics"
  dump_pod_diagnostics infra-llm "app=ollama"
}

# Warm the model into the emptyDir in the background — non-blocking and best-effort.
# Runs `ollama pull` inside the already-running Ollama pod via nohup so it
# survives this exec returning; the pull proceeds server-side and lands in the
# shared ollama-models emptyDir. The deploy does NOT wait for it, so a cold-cluster
# pull no longer blocks bring-up. Ollama also pulls lazily on first request, so
# a slow or failed warm-up is harmless.
_ollama_pod=$(kubectl get pod -n infra-llm -l app=ollama \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "${_ollama_pod}" ]; then
  print_status "Warming model ${LLM_MODEL} in the background (non-blocking)..."
  # Pass the model as a positional arg ("$1") rather than interpolating it into
  # the remote shell string, so a model name with spaces/metacharacters can't be
  # re-parsed inside the pod's `sh -c`.
  kubectl exec -n infra-llm "${_ollama_pod}" -- \
    sh -c 'nohup ollama pull "$1" >/tmp/model-pull.log 2>&1 &' _ "${LLM_MODEL}" 2>/dev/null || \
    print_warning "Could not start background model warm-up — Ollama will pull on first request"
else
  print_warning "Ollama pod not found — skipping warm-up (Ollama will pull on first request)"
fi

print_status "Verifying pods..."
kubectl get pods -n infra-llm

print_status "Verifying Ollama model list (from inside cluster)..."
kubectl run -n infra-llm --rm -i --restart=Never llm-check \
  --image=curlimages/curl:latest \
  -- curl -sf http://ollama.infra-llm.svc.cluster.local:11434/api/tags \
  | python3 -c "import sys,json; models=json.load(sys.stdin)['models']; [print(f'  OK {m[\"name\"]}') for m in models]" \
  2>/dev/null || print_warning "Could not verify model list — check pod logs"

print_success "Ollama inference engine deployed!"
print_success "  API:      http://ollama.infra-llm.svc.cluster.local:11434 (cluster-internal)"
print_success "  OpenAI-compatible endpoint: http://ollama.infra-llm.svc.cluster.local:11434/v1"
