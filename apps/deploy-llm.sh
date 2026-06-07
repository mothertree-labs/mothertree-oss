#!/bin/bash

# Deploy Ollama + Open WebUI to the shared infra-llm namespace
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
  echo "Deploy Ollama + Open WebUI to the shared infra-llm namespace."
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

LLM_DOMAIN=$(yq '.llm.domain // ""' "$MT_INFRA_CONFIG")
if [ -z "$LLM_DOMAIN" ] || [ "$LLM_DOMAIN" = "null" ]; then
  print_error "llm.domain not set in ${MT_INFRA_CONFIG}"
  exit 1
fi

print_status "Deploying LLM stack to env=${MT_ENV}, domain=${LLM_DOMAIN}"

MANIFESTS_DIR="$REPO_ROOT/apps/manifests/llm"
mt_require_commands kubectl yq envsubst

print_status "Applying namespace..."
kubectl apply -f "${MANIFESTS_DIR}/namespace.yaml"

print_status "Applying PVC (model weights storage)..."
kubectl apply -f "${MANIFESTS_DIR}/ollama-pvc.yaml"

print_status "Applying Ollama deployment + service..."
kubectl apply -f "${MANIFESTS_DIR}/ollama.yaml"

print_status "Waiting for Ollama to be ready (model pull may take 15+ minutes on cold-start cluster)..."
kubectl rollout status deployment/ollama -n infra-llm --timeout=1200s || {
  print_warning "Ollama rollout not ready within timeout — dumping pod diagnostics"
  dump_pod_diagnostics infra-llm "app=ollama"
}

print_status "Applying Open WebUI deployment + service + ingress..."
export LLM_DOMAIN
envsubst < "${MANIFESTS_DIR}/open-webui.yaml" | kubectl apply -f -

print_status "Waiting for Open WebUI to be ready..."
kubectl rollout status deployment/open-webui -n infra-llm --timeout=120s

print_status "Verifying pods..."
kubectl get pods -n infra-llm

print_status "Verifying Ollama model list (from inside cluster)..."
kubectl run -n infra-llm --rm -i --restart=Never llm-check \
  --image=curlimages/curl:latest \
  -- curl -sf http://ollama.infra-llm.svc.cluster.local:11434/api/tags \
  | python3 -c "import sys,json; models=json.load(sys.stdin)['models']; [print(f'  OK {m[\"name\"]}') for m in models]" \
  2>/dev/null || print_warning "Could not verify model list — check pod logs"

print_success "LLM stack deployed!"
print_success "  Chat UI:  https://${LLM_DOMAIN}"
print_success "  API:      http://ollama.infra-llm.svc.cluster.local:11434 (cluster-internal)"
print_success "  OpenAI-compatible endpoint: http://ollama.infra-llm.svc.cluster.local:11434/v1"
