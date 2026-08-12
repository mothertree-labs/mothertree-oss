#!/bin/bash

# Deploy Ollama inference engine to the shared infra-llm namespace
# This is a shared-infra service (not per-tenant), so -t/--tenant is not required.
#
# Called by: deploy_infra
# Can also be run standalone.
#
# Ollama is stateless: model weights live in the S3 model cache (Linode Object
# Storage) and are restored into an emptyDir by the pod's initContainer
# (apps/manifests/llm/ollama.yaml.tpl). A one-shot seed Job
# (apps/manifests/llm/ollama-model-seed-job.yaml) populates the bucket from
# ollama.com the first time. See docs/plans/llm/s3-model-cache.md.
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

# Full infra-config load: sets KUBECONFIG, NS_*, LLM_MODEL, and LLM_S3_*
# (non-secret values from infra config, credentials from the infra tenant
# secrets). All required inputs are validated below — no silent skips.
source "${REPO_ROOT}/scripts/lib/infra-config.sh"
mt_load_infra_config

# Fail fast — the restore initContainer and seed Job are expected to run, so a
# missing S3 cache config is a hard error (see CLAUDE.md).
: "${LLM_S3_BUCKET:?LLM_S3_BUCKET not set — add 'llm.s3_bucket' to $MT_INFRA_CONFIG}"
: "${LLM_S3_ENDPOINT:?LLM_S3_ENDPOINT not set — add 'llm.s3_endpoint' to $MT_INFRA_CONFIG}"
: "${LLM_S3_REGION:?LLM_S3_REGION not set — add 'llm.s3_region' to $MT_INFRA_CONFIG}"
: "${LLM_S3_KEY:?LLM_S3_KEY not set — add 'llm.s3_key' to the infra tenant secrets}"
: "${LLM_S3_SECRET:?LLM_S3_SECRET not set — add 'llm.s3_secret' to the infra tenant secrets}"

print_status "Deploying Ollama inference engine to env=${MT_ENV}, model=${LLM_MODEL}"
print_status "  S3 model cache: s3://${LLM_S3_BUCKET}/${LLM_S3_PREFIX} (${LLM_S3_REGION})"

MANIFESTS_DIR="$REPO_ROOT/apps/manifests/llm"
mt_require_commands kubectl yq

print_status "Applying namespace..."
kubectl apply -f "${MANIFESTS_DIR}/namespace.yaml"

mt_reset_change_tracker

# S3 model cache credentials — referenced via envFrom by the restore
# initContainer and the seed Job. Wrapped in mt_apply so a credential change is
# tracked and triggers a rollout (conditional-restart system).
print_status "Creating ollama-s3 secret..."
mt_apply kubectl apply -f <(kubectl create secret generic ollama-s3 \
  --from-literal=AWS_ACCESS_KEY_ID="$LLM_S3_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$LLM_S3_SECRET" \
  --from-literal=AWS_ENDPOINT_URL="https://${LLM_S3_ENDPOINT}" \
  --from-literal=AWS_REGION="$LLM_S3_REGION" \
  -n infra-llm \
  --dry-run=client -o yaml)

print_status "Deploying Ollama..."
export LLM_S3_BUCKET LLM_S3_PREFIX LLM_MODEL
mt_apply kubectl apply -f <(envsubst < "${MANIFESTS_DIR}/ollama.yaml.tpl")

# Restart only when config actually changed (mt_apply tracked it). In particular
# an ollama-s3 credential rotation does not change the pod template, so without
# this the new key would only be picked up on the next unrelated restart.
mt_restart_if_changed deployment/ollama -n infra-llm

print_status "Waiting for Ollama to be ready..."
kubectl rollout status deployment/ollama -n infra-llm --timeout=300s || {
  print_warning "Ollama rollout not ready within timeout — dumping pod diagnostics"
  dump_pod_diagnostics infra-llm "app=ollama"
}

# Seed Job gate — idempotent and non-blocking. The 15-20 min model pull must
# not block deploy_infra (and must not blow the CI tenant-lease TTL), so we
# never `kubectl wait` on it. Skip when the bucket is already seeded or the
# Job is still running; retry when the Job failed (backoffLimit exhausted, e.g.
# a transient ollama.com outage) — a failed Job must not silently suppress
# re-seeding forever. Finished Jobs also self-delete (ttlSecondsAfterFinished).
print_status "Checking whether the model is already in the S3 model cache..."
# Check the model manifest (content-addressed, so presence == seeded). Uses the
# pinned aws-cli image via a throwaway pod that references the ollama-s3 Secret
# through envFrom — the S3 credentials never touch argv or the pod spec (etcd).
# No local aws CLI dependency.
_mt_model_tag="${LLM_MODEL#*:}"
# A bare model name (no :tag) is equivalent to :latest in Ollama's registry
# layout — without this the manifest path would be .../llama3.2/llama3.2 and
# the gate would never find the seeded manifest. The seed Job uploads whatever
# ollama itself wrote (bare names land under .../llama3.2/latest), so the probe
# path must match that.
[[ "${_mt_model_tag}" == "${LLM_MODEL}" ]] && _mt_model_tag="latest"
_mt_model_manifest="s3://${LLM_S3_BUCKET}/${LLM_S3_PREFIX}/models/manifests/registry.ollama.ai/library/${LLM_MODEL%:*}/${_mt_model_tag}"
_mt_seed_skip=""
if kubectl get job ollama-model-seed -n infra-llm >/dev/null 2>&1; then
  # Existence alone is not success: a Job that exhausted backoffLimit would
  # make every future deploy skip while the bucket stays empty. Check the
  # terminal condition instead.
  _mt_seed_complete="$(kubectl get job ollama-model-seed -n infra-llm -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
  _mt_seed_failed="$(kubectl get job ollama-model-seed -n infra-llm -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
  if [[ "${_mt_seed_complete}" == "True" ]]; then
    print_status "Seed Job already completed — skipping (delete the Job to force a re-seed)."
    _mt_seed_skip=1
  elif [[ "${_mt_seed_failed}" == "True" ]]; then
    print_status "Seed Job failed previously (e.g. transient ollama.com outage) — deleting to retry."
    kubectl delete job ollama-model-seed -n infra-llm --wait=false >/dev/null 2>&1 || true
  else
    print_status "Seed Job still running — skipping (it populates the bucket when done)."
    _mt_seed_skip=1
  fi
fi
if [[ -z "${_mt_seed_skip}" ]]; then
  _mt_check_pod="ollama-seed-check-$$"
  _mt_seed_manifest=$(mktemp) || exit 1
  cat > "${_mt_seed_manifest}" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${_mt_check_pod}
  namespace: infra-llm
spec:
  restartPolicy: Never
  containers:
    - name: check
      image: amazon/aws-cli:2.22.35
      args: ["s3", "ls", "${_mt_model_manifest}"]
      envFrom:
        - secretRef:
            name: ollama-s3
EOF
  if kubectl create -f "${_mt_seed_manifest}" >/dev/null 2>&1; then
    # Poll for a terminal phase (Succeeded or Failed) — accept both. If the
    # pod is still Pending after the cap (e.g. slow aws-cli image pull on a
    # cold node), treat it as "not seeded": that is the right default on first
    # boot, where an empty bucket and a cold node coincide. A false apply on a
    # warm, already-seeded bucket is harmless — the seed Job is idempotent and
    # self-cleans via ttlSecondsAfterFinished — so a longer cap (120s) only
    # narrows that window without risking first-boot seeding.
    _mt_phase=""
    for _ in $(seq 1 60); do
      _mt_phase="$(kubectl get pod "${_mt_check_pod}" -n infra-llm -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      if [[ "${_mt_phase}" == "Succeeded" || "${_mt_phase}" == "Failed" ]]; then
        break
      fi
      sleep 2
    done
    if [[ "${_mt_phase}" == "Succeeded" ]]; then
      print_status "Model manifest already in S3 cache — skipping seed Job."
    else
      print_status "Bucket not seeded — applying seed Job (populates S3 in the background)..."
      export LLM_MODEL
      kubectl apply -f <(envsubst < "${MANIFESTS_DIR}/ollama-model-seed-job.yaml")
      print_status "Seed Job applied — deploy continues without waiting for the model pull."
    fi
  else
    print_status "Could not create seed-check pod — applying seed Job (idempotent) instead."
    export LLM_MODEL
    kubectl apply -f <(envsubst < "${MANIFESTS_DIR}/ollama-model-seed-job.yaml")
    print_status "Seed Job applied — deploy continues without waiting for the model pull."
  fi
  rm -f "${_mt_seed_manifest}"
  kubectl delete pod "${_mt_check_pod}" -n infra-llm --wait=false >/dev/null 2>&1 || true
fi

print_status "Verifying pods..."
kubectl get pods -n infra-llm

print_status "Verifying Ollama model list (from inside cluster)..."
kubectl run -n infra-llm --rm -i --restart=Never llm-check \
  --image=curlimages/curl:8.12.1 \
  -- curl -sf http://ollama.infra-llm.svc.cluster.local:11434/api/tags \
  | python3 -c "import sys,json; models=json.load(sys.stdin)['models']; [print(f'  OK {m[\"name\"]}') for m in models]" \
  2>/dev/null || print_warning "Could not verify model list — check pod logs"

print_success "Ollama inference engine deployed!"
print_success "  API:      http://ollama.infra-llm.svc.cluster.local:11434 (cluster-internal)"
print_success "  OpenAI-compatible endpoint: http://ollama.infra-llm.svc.cluster.local:11434/v1"
