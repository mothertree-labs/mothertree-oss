#!/bin/bash

# Deploy the shared LLM infrastructure to the infra-llm namespace:
#   - Ollama inference engine (app: ollama)
#   - SearXNG metasearch engine for Open WebUI web search (app: searxng)
# This is shared-infra (not per-tenant), so -t/--tenant is not required.
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

# Canonical model ref — bare names (no :tag) are equivalent to :latest in
# Ollama's registry layout, and `ollama list` prints the tag explicitly. Both
# the pod's model-presence check (ollama.yaml.tpl) and the S3 manifest probe
# below must use the canonical form or a tagless llm.model never matches.
_mt_model_tag="${LLM_MODEL#*:}"
[[ "${_mt_model_tag}" == "${LLM_MODEL}" ]] && _mt_model_tag="latest"
LLM_MODEL_CANONICAL="${LLM_MODEL%:*}:${_mt_model_tag}"
# The model ref is pasted textually into pod shell scripts by envsubst below —
# constrain it to Ollama's ref grammar so a malformed/malicious llm.model can
# never inject shell or corrupt the rendered YAML.
[[ "${LLM_MODEL_CANONICAL}" =~ ^[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] || {
  print_error "Invalid llm.model '${LLM_MODEL}' — expected [name[:tag]] with [A-Za-z0-9._/-] only"
  exit 1
}

print_status "Deploying Ollama..."
export LLM_S3_BUCKET LLM_S3_PREFIX LLM_MODEL LLM_MODEL_CANONICAL
# Whitelist the substituted variables: bare envsubst would substitute ANY
# exported var a template references (and blank unknowns) — this makes the
# contract explicit and keeps unrelated env values out of rendered manifests.
_MT_ENVSUBST_VARS='${LLM_MODEL} ${LLM_MODEL_CANONICAL} ${LLM_S3_BUCKET} ${LLM_S3_PREFIX}'
mt_apply kubectl apply -f <(envsubst "${_MT_ENVSUBST_VARS}" < "${MANIFESTS_DIR}/ollama.yaml.tpl")

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
# The seed Job uploads whatever ollama itself wrote (bare names land under
# .../<name>/latest), so the probe path uses the canonical tag computed above.
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
    # Wait for the deletion to finish: the re-apply below would error against a
    # still-terminating Job object and set -e would fail the whole deploy.
    # Bounded so a finalizer-stuck object can't hang the deploy indefinitely.
    kubectl delete job ollama-model-seed -n infra-llm --timeout=60s >/dev/null 2>&1 || true
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
      kubectl apply -f <(envsubst "${_MT_ENVSUBST_VARS}" < "${MANIFESTS_DIR}/ollama-model-seed-job.yaml")
      print_status "Seed Job applied — deploy continues without waiting for the model pull."
    fi
  else
    print_status "Could not create seed-check pod — applying seed Job (idempotent) instead."
    export LLM_MODEL
    kubectl apply -f <(envsubst "${_MT_ENVSUBST_VARS}" < "${MANIFESTS_DIR}/ollama-model-seed-job.yaml")
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

# ---------------------------------------------------------------------------
# SearXNG metasearch engine — shared infra-llm service powering Open WebUI web
# search (the alternative-provider route from docs/plans/llm/web-search.md:
# self-hosted metasearch, no external API key). Keyless JSON API consumed by
# Open WebUI tenants via SEARXNG_QUERY_URL.
# ---------------------------------------------------------------------------
print_status "Deploying SearXNG metasearch engine..."
mt_reset_change_tracker

# Stable cookie-signing key across deploys: reuse the existing secret's key
# when present, otherwise generate one (read-or-generate, same pattern as the
# repo's password helpers). The key only signs the SearXNG UI's own cookies —
# the Open WebUI JSON API is keyless — but it MUST differ from the image
# default "ultrasecretkey", which SearXNG refuses to start with.
SEARXNG_SECRET_KEY="$(kubectl get secret searxng-settings -n infra-llm -o yaml 2>/dev/null \
  | yq '.data["settings.yml"] // ""' 2>/dev/null \
  | base64 -d 2>/dev/null \
  | sed -n 's/^[[:space:]]*secret_key:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [ -z "$SEARXNG_SECRET_KEY" ]; then
  print_status "No existing SearXNG secret key found — generating one"
  SEARXNG_SECRET_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
fi
export SEARXNG_SECRET_KEY

# The settings Secret is applied OUTSIDE mt_apply: kubectl client-side apply
# always reports "configured" for a stringData Secret (stored as data but
# annotated as stringData), which would otherwise force a restart on every
# deploy. Real settings changes are detected by diffing the settings.yml
# content before/after the apply instead.
_mt_searxng_prev="$(kubectl get secret searxng-settings -n infra-llm -o yaml 2>/dev/null \
  | yq '.data["settings.yml"] // ""' 2>/dev/null | base64 -d 2>/dev/null || true)"

kubectl apply -f <(envsubst '${SEARXNG_SECRET_KEY}' < "${MANIFESTS_DIR}/searxng-settings.yaml.tpl")

_mt_searxng_cur="$(kubectl get secret searxng-settings -n infra-llm -o yaml 2>/dev/null \
  | yq '.data["settings.yml"] // ""' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [ "${_mt_searxng_prev}" != "${_mt_searxng_cur}" ]; then
  print_status "SearXNG settings changed — restart will be triggered"
  _mt_deploy_changed=true
fi

# Deployment + Service go through the change tracker normally.
mt_apply kubectl apply -f <(envsubst '${SEARXNG_SECRET_KEY}' < "${MANIFESTS_DIR}/searxng.yaml.tpl")

# Restart on config change (e.g. the settings secret changing) so the new
# settings are actually picked up — same conditional-restart pattern as Ollama.
mt_restart_if_changed deployment/searxng -n infra-llm

print_status "Waiting for SearXNG to be ready..."
kubectl rollout status deployment/searxng -n infra-llm --timeout=180s || {
  print_warning "SearXNG rollout not ready within timeout — dumping pod diagnostics"
  dump_pod_diagnostics infra-llm "app=searxng"
}

print_status "Verifying SearXNG health endpoint..."
kubectl run -n infra-llm --rm -i --restart=Never searxng-health-check \
  --image=curlimages/curl:8.12.1 \
  -- curl -sf http://searxng.infra-llm.svc.cluster.local:8080/healthz >/dev/null 2>&1 \
  && print_success "SearXNG health endpoint OK" \
  || print_warning "SearXNG health check failed — check pod logs"

print_success "SearXNG metasearch engine deployed!"
print_success "  API:  http://searxng.infra-llm.svc.cluster.local:8080/search?format=json"
