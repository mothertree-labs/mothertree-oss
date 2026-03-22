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
#   GITHUB_PAT            — GitHub PAT for cloning private config submodules
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
  # Stop lease renewal background process
  [[ -n "${_LEASE_RENEWAL_PID:-}" ]] && kill "$_LEASE_RENEWAL_PID" 2>/dev/null || true
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

# ── Clone private config submodules ───────────────────────────────
# Use GitHub PAT to authenticate SSH-based submodule URLs via URL rewriting.
# Must be --global so child git processes (spawned by submodule update) inherit it.
cd "$REPO_ROOT"
if [[ -n "${GITHUB_PAT:-}" ]]; then
  git config --global url."https://x-access-token:${GITHUB_PAT}@github.com/".insteadOf "git@github.com:"
  echo "Configured git URL rewriting for private submodule access"
fi

echo "Initializing config submodules..."
git submodule update --init config/platform config/tenants || {
  echo "ERROR: Failed to init config submodules."
  echo "Ensure GITHUB_PAT secret is set and has access to the private config repos."
  exit 1
}

# ── Copy secrets from vault into workspace ────────────────────────
# Config files come from submodules; secrets come from the encrypted vault.
if [[ -d "$WORK_DIR/tenants" ]]; then
  for tenant_secrets_dir in "$WORK_DIR/tenants"/*/; do
    [[ -d "$tenant_secrets_dir" ]] || continue
    tenant_name=$(basename "$tenant_secrets_dir")
    target_dir="$REPO_ROOT/config/tenants/$tenant_name"
    if [[ -d "$target_dir" ]]; then
      cp "$tenant_secrets_dir"/*.secrets.yaml "$target_dir/" 2>/dev/null || true
      echo "  Copied secrets for tenant: $tenant_name"
    else
      echo "  WARNING: Tenant config dir not found: $target_dir (skipping secrets)"
    fi
  done
else
  echo "ERROR: No tenants/ directory in vault archive"
  exit 1
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

# ── Keep tenant lease alive during deploy ─────────────────────────
# The deploy can take 10+ minutes but the Valkey lease TTL is 600s.
# Renew both the lease key and reverse-lookup key every 120s in the background.
_LEASE_RENEWAL_PID=""
if [[ "$ALL_TENANTS" != "true" ]] && [[ -n "${CI_VALKEY_PASSWORD:-}" ]] && [[ -n "${CI_PIPELINE_NUMBER:-}" ]]; then
  _VCLI=$(command -v valkey-cli 2>/dev/null || command -v redis-cli)
  _POOL=$($_VCLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
    GET "ci-build-${CI_PIPELINE_NUMBER}" 2>/dev/null || echo "")
  (
    while true; do
      sleep 120
      $_VCLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
        EXPIRE "ci-lease-${_POOL}" 600 >/dev/null 2>&1 || true
      $_VCLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
        EXPIRE "ci-build-${CI_PIPELINE_NUMBER}" 600 >/dev/null 2>&1 || true
      echo "Renewed tenant lease (pool=${_POOL}, pipeline=#${CI_PIPELINE_NUMBER})"
    done
  ) &
  _LEASE_RENEWAL_PID=$!
  echo "Started lease renewal background process (PID: $_LEASE_RENEWAL_PID)"
fi

# ── Acquire deploy lock ──────────────────────────────────────────
# Valkey-based locking to prevent concurrent deploys to the same env.
#
# Dev (PRs): Simple sequential lock. Two PRs deploy different tenants
#   but share deploy_infra, so they wait for each other.
#
# Prod (main merges): Smart last-writer-wins. If multiple merges land
#   while a deploy is running, only the latest one actually deploys.
#   Intermediate pipelines abort (their code will be deployed by the
#   latest one anyway). Uses a "pending" key that gets overwritten:
#     - Pipeline A deploys, acquires lock
#     - Pipeline B arrives, sets pending=B, waits
#     - Pipeline C arrives, overwrites pending=C, waits
#     - A finishes, releases lock
#     - B checks pending → "C" (not "B") → aborts
#     - C checks pending → "C" (itself) → acquires lock, deploys

_release_deploy_lock() {
  if [[ -n "${_DEPLOY_LOCK_ACQUIRED:-}" ]]; then
    echo "Releasing deploy lock..."
    $_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
      DEL "$LOCK_KEY" >/dev/null 2>&1 || true
  fi
}

_DEPLOY_LOCK_ACQUIRED=""
: "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required for deploy locking}"
_CLI=$(command -v valkey-cli 2>/dev/null || command -v redis-cli)
LOCK_KEY="ci-deploy-${MT_ENV}"
PENDING_KEY="ci-deploy-pending-${MT_ENV}"
LOCK_TTL=2400  # 40 min (prod deploy can take 20-30 min)
MAX_WAIT=2400
ELAPSED=0

echo "Acquiring deploy lock ($LOCK_KEY)..."
RESULT=$($_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
  SET "$LOCK_KEY" "$CI_PIPELINE_NUMBER" NX EX "$LOCK_TTL" 2>/dev/null || true)

if [[ "$RESULT" == "OK" ]]; then
  _DEPLOY_LOCK_ACQUIRED=1
  echo "Acquired deploy lock (pipeline #$CI_PIPELINE_NUMBER)"
else
  # Lock is held — register as pending (overwrites any previous pending)
  HOLDER=$($_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
    GET "$LOCK_KEY" 2>/dev/null || echo "unknown")
  echo "Deploy lock held by pipeline #$HOLDER"

  if [[ "$ALL_TENANTS" == "true" ]]; then
    # Prod: smart last-writer-wins
    $_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
      SET "$PENDING_KEY" "$CI_PIPELINE_NUMBER" EX "$MAX_WAIT" >/dev/null 2>&1
    echo "Registered as pending deploy (pipeline #$CI_PIPELINE_NUMBER)"
  fi

  # Wait for lock to be released
  while true; do
    sleep 30
    ELAPSED=$((ELAPSED + 30))
    if (( ELAPSED >= MAX_WAIT )); then
      echo "ERROR: Could not acquire deploy lock after ${MAX_WAIT}s"
      exit 1
    fi

    # For prod: check if we've already been superseded before even trying the lock
    if [[ "$ALL_TENANTS" == "true" ]]; then
      CURRENT_PENDING=$($_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
        GET "$PENDING_KEY" 2>/dev/null || echo "")
      if [[ -n "$CURRENT_PENDING" ]] && [[ "$CURRENT_PENDING" != "$CI_PIPELINE_NUMBER" ]]; then
        echo "Superseded by pipeline #$CURRENT_PENDING while waiting — skipping deploy"
        echo "=== Deploy skipped (newer merge will deploy) ==="
        exit 0
      fi
    fi

    # Try to acquire the lock
    RESULT=$($_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
      SET "$LOCK_KEY" "$CI_PIPELINE_NUMBER" NX EX "$LOCK_TTL" 2>/dev/null || true)
    if [[ "$RESULT" == "OK" ]]; then
      # Got the lock — but for prod, only proceed if we're still the pending one.
      # If pending key is empty (someone else already deployed and cleared it)
      # or someone else (a newer pipeline overwrote us), we're stale — abort.
      if [[ "$ALL_TENANTS" == "true" ]]; then
        CURRENT_PENDING=$($_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
          GET "$PENDING_KEY" 2>/dev/null || echo "")
        if [[ "$CURRENT_PENDING" != "$CI_PIPELINE_NUMBER" ]]; then
          # We've been superseded — release lock and abort
          $_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
            DEL "$LOCK_KEY" >/dev/null 2>&1 || true
          echo "Superseded (pending=${CURRENT_PENDING:-<empty>}, us=$CI_PIPELINE_NUMBER) — skipping deploy"
          echo "=== Deploy skipped (newer merge will deploy) ==="
          exit 0
        fi
        # We're the latest — clear pending key
        $_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
          DEL "$PENDING_KEY" >/dev/null 2>&1 || true
      fi
      _DEPLOY_LOCK_ACQUIRED=1
      echo "Acquired deploy lock (pipeline #$CI_PIPELINE_NUMBER)"
      break
    fi

    HOLDER=$($_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
      GET "$LOCK_KEY" 2>/dev/null || echo "unknown")
    echo "Deploy lock held by #$HOLDER, waiting... ($ELAPSED/${MAX_WAIT}s)"
  done
fi

trap '_release_deploy_lock; _cleanup' EXIT

echo ""
echo "=== Running deploy_infra -e $MT_ENV ==="
"$REPO_ROOT/scripts/deploy_infra" -e "$MT_ENV"

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
