#!/usr/bin/env bash
set -euo pipefail

# CI Deploy Script — runs deploy_infra + create_env in Woodpecker pipelines.
#
# Decrypts an Ansible Vault-encrypted archive containing kubeconfigs,
# terraform outputs, and tenant secrets into a temp directory, runs the
# deploy scripts, then cleans up decrypted files on exit.
#
# Usage:
#   ci/scripts/ci-deploy.sh <env>                # Dev: deploy leased tenant
#   ci/scripts/ci-deploy.sh <env> --all-tenants  # Prod: deploy all tenants
#
# Required environment variables:
#   DEPLOY_VAULT_PASSWORD — Ansible Vault password (from Woodpecker secret)
#   CI_VALKEY_PASSWORD    — Valkey password for deploy lock (dev only)
#   CI_PIPELINE_NUMBER    — Woodpecker pipeline number (for lease resolution)
#
# Pool-prefixed tenant vars (dev only, from Woodpecker secrets):
#   E2E_POOL1_TENANT, E2E_POOL2_TENANT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MT_ENV="${1:?Usage: ci-deploy.sh <env> [--all-tenants]}"
ALL_TENANTS=false
if [[ "${2:-}" == "--all-tenants" ]]; then
  ALL_TENANTS=true
fi

: "${DEPLOY_VAULT_PASSWORD:?DEPLOY_VAULT_PASSWORD is required}"

echo "=== CI Deploy: env=$MT_ENV all_tenants=$ALL_TENANTS pipeline=#${CI_PIPELINE_NUMBER:-unknown} ==="

# ── Decrypt vault ────────────────────────────────────────────────
VAULT_FILE="/home/woodpecker/deploy-vaults/deploy-vault-${MT_ENV}.vault"
if [[ ! -f "$VAULT_FILE" ]]; then
  echo "ERROR: Deploy vault not found: $VAULT_FILE"
  echo "Run Ansible to provision vault files to the CI host."
  exit 1
fi

WORK_DIR=$(mktemp -d /tmp/mt-deploy-XXXXXX)
chmod 0700 "$WORK_DIR"

_cleanup() {
  # Remove decrypted vault contents
  rm -rf "$WORK_DIR"
  # Remove secrets copied into worktree
  if [[ -d "$REPO_ROOT/config/tenants" ]]; then
    find "$REPO_ROOT/config/tenants" -name "*.secrets.yaml" -newer "$0" -delete 2>/dev/null || true
  fi
}
trap _cleanup EXIT

echo "Decrypting deploy vault ($MT_ENV) → $WORK_DIR"
ansible-vault decrypt "$VAULT_FILE" \
  --vault-password-file <(echo "$DEPLOY_VAULT_PASSWORD") \
  --output "$WORK_DIR/secrets.tar.gz"
tar xzf "$WORK_DIR/secrets.tar.gz" -C "$WORK_DIR"
rm -f "$WORK_DIR/secrets.tar.gz"
echo "Vault decrypted successfully"

# ── Set up environment ───────────────────────────────────────────
export KUBECONFIG="$WORK_DIR/kubeconfig.yaml"
export MT_TERRAFORM_OUTPUTS_FILE="$WORK_DIR/terraform-outputs.env"

if [[ ! -f "$KUBECONFIG" ]]; then
  echo "ERROR: kubeconfig.yaml not found in vault archive"
  ls -la "$WORK_DIR/"
  exit 1
fi

if [[ ! -f "$MT_TERRAFORM_OUTPUTS_FILE" ]]; then
  echo "ERROR: terraform-outputs.env not found in vault archive"
  ls -la "$WORK_DIR/"
  exit 1
fi

# ── Initialize config submodules ─────────────────────────────────
echo "Initializing config submodules..."
cd "$REPO_ROOT"
git submodule update --init config/platform config/tenants 2>/dev/null || {
  echo "WARNING: Could not init config submodules (may already be initialized)"
}

# ── Copy secrets into workspace ──────────────────────────────────
# The deploy scripts expect secrets alongside config files in config/tenants/
if [[ -d "$WORK_DIR/tenants" ]]; then
  for tenant_secrets_dir in "$WORK_DIR/tenants"/*/; do
    [[ -d "$tenant_secrets_dir" ]] || continue
    tenant_name=$(basename "$tenant_secrets_dir")
    target_dir="$REPO_ROOT/config/tenants/$tenant_name"
    if [[ -d "$target_dir" ]]; then
      cp "$tenant_secrets_dir"/*.secrets.yaml "$target_dir/" 2>/dev/null || true
      echo "Copied secrets for tenant: $tenant_name"
    else
      echo "WARNING: Tenant config dir not found: $target_dir (skipping secrets copy)"
    fi
  done
else
  echo "WARNING: No tenants/ directory in vault archive"
fi

# ── Resolve tenant(s) to deploy ──────────────────────────────────
TENANTS=()

if [[ "$ALL_TENANTS" == "true" ]]; then
  # Prod: iterate all tenants with a config for this environment
  for config_file in "$REPO_ROOT/config/tenants"/*/"${MT_ENV}.config.yaml"; do
    [[ -f "$config_file" ]] || continue
    tenant=$(basename "$(dirname "$config_file")")
    [[ "$tenant" == ".example" ]] && continue
    TENANTS+=("$tenant")
  done
  echo "Discovered ${#TENANTS[@]} tenant(s) for $MT_ENV: ${TENANTS[*]}"
else
  # Dev: resolve the leased tenant from Valkey pool
  : "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required for dev deploy}"
  : "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required for dev deploy}"

  # Source the resolve script to get E2E_TENANT
  source "$REPO_ROOT/ci/scripts/ci-resolve-tenant.sh"
  if [[ -z "${E2E_TENANT:-}" ]]; then
    echo "ERROR: Could not resolve leased tenant from Valkey"
    exit 1
  fi
  TENANTS=("$E2E_TENANT")
  echo "Leased tenant for dev deploy: $E2E_TENANT"
fi

if [[ ${#TENANTS[@]} -eq 0 ]]; then
  echo "ERROR: No tenants to deploy"
  exit 1
fi

# ── Deploy infrastructure ────────────────────────────────────────
# For dev: use a Valkey lock to prevent concurrent deploy_infra runs
# (shared infra — Helm conflicts if two PRs modify simultaneously)
_release_deploy_lock() {
  if [[ -n "${_DEPLOY_LOCK_ACQUIRED:-}" ]]; then
    echo "Releasing deploy_infra lock..."
    $_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
      DEL "$LOCK_KEY" >/dev/null 2>&1 || true
  fi
}

_DEPLOY_LOCK_ACQUIRED=""
if [[ "$ALL_TENANTS" != "true" ]] && [[ -n "${CI_VALKEY_PASSWORD:-}" ]]; then
  _CLI=$(command -v valkey-cli 2>/dev/null || command -v redis-cli)
  LOCK_KEY="ci-deploy-infra-${MT_ENV}"
  LOCK_TTL=900
  MAX_WAIT=600
  ELAPSED=0

  echo "Acquiring deploy_infra lock ($LOCK_KEY)..."
  while true; do
    RESULT=$($_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
      SET "$LOCK_KEY" "$CI_PIPELINE_NUMBER" NX EX "$LOCK_TTL" 2>/dev/null || true)
    if [[ "$RESULT" == "OK" ]]; then
      _DEPLOY_LOCK_ACQUIRED=1
      echo "Acquired deploy_infra lock (pipeline #$CI_PIPELINE_NUMBER)"
      break
    fi
    HOLDER=$($_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
      GET "$LOCK_KEY" 2>/dev/null || echo "unknown")
    echo "deploy_infra lock held by pipeline #$HOLDER, waiting... ($ELAPSED/${MAX_WAIT}s)"
    if (( ELAPSED >= MAX_WAIT )); then
      echo "ERROR: Could not acquire deploy_infra lock after ${MAX_WAIT}s"
      exit 1
    fi
    sleep 30
    ELAPSED=$((ELAPSED + 30))
  done

  # Extend the cleanup trap to also release the lock
  trap '_release_deploy_lock; _cleanup' EXIT
fi

echo ""
echo "=== Running deploy_infra -e $MT_ENV ==="
"$REPO_ROOT/scripts/deploy_infra" -e "$MT_ENV"

# Release the deploy lock immediately after deploy_infra completes
# (create_env is per-tenant and safe to run concurrently)
_release_deploy_lock

echo ""
echo "=== deploy_infra complete ==="

# ── Deploy tenant(s) ─────────────────────────────────────────────
FAILED_TENANTS=()
for tenant in "${TENANTS[@]}"; do
  echo ""
  echo "=== Running create_env -e $MT_ENV -t $tenant ==="
  if "$REPO_ROOT/scripts/create_env" -e "$MT_ENV" -t "$tenant"; then
    echo "=== Tenant $tenant deployed successfully ==="
  else
    echo "=== FAILED: Tenant $tenant deploy failed ==="
    FAILED_TENANTS+=("$tenant")
    # Continue deploying remaining tenants (prod multi-tenant resilience)
    if [[ "$ALL_TENANTS" != "true" ]]; then
      exit 1  # For dev (single tenant), fail immediately
    fi
  fi
done

echo ""
if [[ ${#FAILED_TENANTS[@]} -gt 0 ]]; then
  echo "ERROR: Failed tenants: ${FAILED_TENANTS[*]}"
  exit 1
fi

echo "=== CI Deploy complete: env=$MT_ENV tenants=${TENANTS[*]} ==="
