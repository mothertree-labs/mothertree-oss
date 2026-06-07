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

LLM_MODEL=$(yq '.llm.model // "llama3.2:1b"' "$MT_INFRA_CONFIG")

print_status "Deploying LLM stack to env=${MT_ENV}, domain=${LLM_DOMAIN}, model=${LLM_MODEL}"

MANIFESTS_DIR="$REPO_ROOT/apps/manifests/llm"
mt_require_commands kubectl yq envsubst

print_status "Applying namespace..."
kubectl apply -f "${MANIFESTS_DIR}/namespace.yaml"

print_status "Applying PVC (model weights storage)..."
kubectl apply -f "${MANIFESTS_DIR}/ollama-pvc.yaml"

# Pre-pull model into PVC before deploying Ollama, so the pod starts instantly.
# If the pull fails or times out, Ollama will pull the model lazily on first request.
print_status "Pre-pulling model ${LLM_MODEL} into PVC (this may take 5-15 minutes on first run)..."
kubectl delete pod ollama-model-pull -n infra-llm --ignore-not-found --grace-period=0 2>/dev/null || true
cat <<PODEOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ollama-model-pull
  namespace: infra-llm
spec:
  restartPolicy: Never
  volumes:
    - name: ollama-models
      persistentVolumeClaim:
        claimName: ollama-models
  containers:
    - name: pull-model
      image: ollama/ollama:latest
      command:
        - sh
        - -c
        - |
          ollama serve &
          OLLAMA_PID=\$!
          until curl -sf http://localhost:11434/api/tags > /dev/null; do sleep 1; done
          echo "Pulling model ${LLM_MODEL}..."
          ollama pull ${LLM_MODEL}
          kill \$OLLAMA_PID
          echo "Model pulled successfully"
      env:
        - name: OLLAMA_HOST
          value: "0.0.0.0"
      volumeMounts:
        - name: ollama-models
          mountPath: /root/.ollama
PODEOF

kubectl wait --for=condition=phase=Succeeded pod/ollama-model-pull -n infra-llm --timeout=900s 2>/dev/null || \
  print_warning "Model pull not complete within timeout — Ollama will pull on first request"
kubectl delete pod ollama-model-pull -n infra-llm --ignore-not-found --grace-period=0 2>/dev/null || true

print_status "Deploying Ollama..."
kubectl apply -f "${MANIFESTS_DIR}/ollama.yaml"

print_status "Waiting for Ollama to be ready..."
kubectl rollout status deployment/ollama -n infra-llm --timeout=300s || {
  print_warning "Ollama rollout not ready within timeout — dumping pod diagnostics"
  dump_pod_diagnostics infra-llm "app=ollama"
}

print_status "Applying Open WebUI deployment + service + ingress..."
export LLM_DOMAIN
envsubst < "${MANIFESTS_DIR}/open-webui.yaml" | kubectl apply -f -

print_status "Waiting for Open WebUI to be ready..."
kubectl rollout status deployment/open-webui -n infra-llm --timeout=120s

# =============================================================================
# Create DNS A record for the LLM domain (points to the cluster ingress LB)
# =============================================================================
print_status "Creating DNS record for ${LLM_DOMAIN}..."
INGRESS_LB_IP=$(kubectl get service -n "$NS_INGRESS" ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [ -n "$INGRESS_LB_IP" ] && [ -n "${TF_VAR_cloudflare_api_token:-}" ] && [ -n "${TF_VAR_cloudflare_zone_id:-}" ]; then
  source "${REPO_ROOT}/scripts/lib/dns.sh"
  create_dns_record "$LLM_DOMAIN" "A" "$INGRESS_LB_IP"
  print_status "DNS record created: ${LLM_DOMAIN} -> ${INGRESS_LB_IP}"
elif [ -z "$INGRESS_LB_IP" ]; then
  print_warning "Could not get ingress LB IP — DNS record not created"
  print_warning "Create manually: $LLM_DOMAIN A <ingress-lb-ip>"
else
  print_warning "Cloudflare credentials not available — DNS record not created"
  print_warning "Create manually: $LLM_DOMAIN A <ingress-lb-ip>"
fi

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
