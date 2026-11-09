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
#   CI_VALKEY_PASSWORD    — Valkey password for tenant lease (dev) and deploy lock (prod)
#   CI_PIPELINE_NUMBER    — Woodpecker pipeline number (for lease resolution)
#
# Pool-prefixed tenant vars (dev only, from Woodpecker secrets):
#   E2E_POOL1_TENANT, E2E_POOL2_TENANT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=ci-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/ci-lib.sh"
MT_ENV="${1:?Usage: ci-deploy.sh <env> [--all-tenants] [--prep-only] [--bringup-only]}"
ALL_TENANTS=false
PREP_ONLY=false
BRINGUP_ONLY=false
for arg in "${@:2}"; do
  case "$arg" in
    --all-tenants)  ALL_TENANTS=true ;;
    --prep-only)    PREP_ONLY=true ;;
    --bringup-only) BRINGUP_ONLY=true ;;
  esac
done

: "${DEPLOY_VAULT_PASSWORD:?DEPLOY_VAULT_PASSWORD is required}"

echo "=== CI Deploy: env=$MT_ENV all_tenants=$ALL_TENANTS pipeline=#${CI_PIPELINE_NUMBER:-unknown} ==="

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

# ── Lease renewal ─────────────────────────────────────────────────
# Start a background loop that renews the Valkey pool lease (and its
# reverse-lookup key) every 120s. The PR lease TTL is 1000s (~17 min), and a
# tenant deploy can run longer than that. Sets the global _LEASE_RENEWAL_PID so the EXIT
# trap (_cleanup) can stop it. Idempotent: a second call is a no-op.
_start_lease_renewal() {
  [[ -n "${_LEASE_RENEWAL_PID:-}" ]] && return 0          # already running
  [[ "$ALL_TENANTS" == "true" ]] && return 0             # prod resolves all tenants, no pool lease
  [[ -z "${CI_VALKEY_PASSWORD:-}" || -z "${CI_PIPELINE_NUMBER:-}" ]] && return 0
  local _VCLI _POOL
  _VCLI=$(command -v valkey-cli 2>/dev/null || command -v redis-cli)
  _POOL=$($_VCLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
    GET "ci-build-${CI_PIPELINE_NUMBER}" 2>/dev/null || echo "")
  (
    # Interruptible 120s wait with no child process: read from a FIFO that has
    # no writer, so it never delivers data or EOF and `read -t` times out after
    # the full 120s. `read` is a builtin that EINTRs on SIGTERM, so the EXIT
    # trap's kill stops this loop promptly and leaves no orphan — unlike `sleep`,
    # which would outlive the killed subshell and make Woodpecker hang up to
    # 120s. (Reading from /dev/null hits EOF instantly and busy-spins.)
    _wait_fifo=$(mktemp -u); mkfifo "$_wait_fifo"; exec 9<>"$_wait_fifo"; rm -f "$_wait_fifo"
    while true; do
      read -t 120 -u 9 _ || true
      $_VCLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
        EXPIRE "ci-lease-${_POOL}" 1000 >/dev/null 2>&1 || true
      $_VCLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
        EXPIRE "ci-build-${CI_PIPELINE_NUMBER}" 1000 >/dev/null 2>&1 || true
      echo "Renewed tenant lease (pool=${_POOL}, pipeline=#${CI_PIPELINE_NUMBER})"
    done
  ) &
  _LEASE_RENEWAL_PID=$!
  echo "Started lease renewal background process (PID: $_LEASE_RENEWAL_PID)"
}

# ── Clone private config submodules (provides the committed vault) ──
# config/platform carries the committed deploy vaults, so the submodules MUST be
# cloned before decryption. This used to happen AFTER the decrypt, when the vault
# came from the CI host; GitHub issue #463 moved the source of truth to the
# committed copy so a merged vault change deploys with no operator reprovision.
ci_clone_config_submodules "$REPO_ROOT"

# ── Decrypt vault (from the committed config/platform copy) ───────
echo "Decrypting deploy vault ($MT_ENV) → $WORK_DIR"
ci_decrypt_committed_vault "$REPO_ROOT" "$MT_ENV" "$WORK_DIR/secrets.tar.gz"
tar xzf "$WORK_DIR/secrets.tar.gz" -C "$WORK_DIR"
rm -f "$WORK_DIR/secrets.tar.gz"
echo "Vault decrypted successfully"

# ── Set up environment ───────────────────────────────────────────
# The kubeconfig comes from the vault: every env CI deploys to (devhome,
# prod) is a permanent cluster.
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

# Source the terraform outputs (TURN / Headscale / PostgreSQL addresses) for
# the child scripts. `set -a` exports every assignment in the file.
set -a
# shellcheck disable=SC1090
source "$MT_TERRAFORM_OUTPUTS_FILE"
set +a

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

# ── Bring-up check (ensure-dev-cluster) ───────────────────────────
# The dev-class CI env (devhome) is a permanent k3s cluster: there is nothing
# to bring up. Prove the API answers with the vaulted kubeconfig so a dead box
# fails HERE, with a clear message, rather than in the first app deploy.
if [[ "$BRINGUP_ONLY" == "true" ]]; then
  source "$REPO_ROOT/scripts/lib/platform.sh"
  if ! mt_is_k3s; then
    echo "ERROR: --bringup-only is only supported for a k3s env (got $MT_ENV)" >&2
    exit 1
  fi
  echo "=== Bring-up only: $MT_ENV is a permanent k3s cluster — checking it is reachable ==="
  if ! kubectl get nodes -o wide; then
    echo "ERROR: the $MT_ENV k3s API is unreachable with the vaulted kubeconfig — is the devhome box up?" >&2
    exit 1
  fi
  exit 0
fi

# ── Resolve tenant(s) to deploy ──────────────────────────────────
TENANTS=()

if [[ "$ALL_TENANTS" == "true" ]]; then
  # Prod: iterate all tenants with a config for this environment
  for config_file in "$REPO_ROOT/config/tenants"/*/"${MT_ENV}.config.yaml"; do
    [[ -f "$config_file" ]] || continue
    tenant=$(basename "$(dirname "$config_file")")
    [[ "$tenant" == ".example" ]] && continue
    # Skip infra-only configs (no deployable tenant apps)
    if [[ "$(yq '.tenant.infra_only // false' "$config_file")" == "true" ]]; then
      echo "Skipping infra-only tenant: $tenant"
      continue
    fi
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

  # Dev deploys ONLY the leased tenant — prep included. Every dev tenant is a
  # pool tenant, so "the other tenants" are exactly the ones another pipeline
  # may have leased and be deploying/testing right now. Prepping them here
  # (added in #446 for the LLM step) ran a full create_env --prep-only —
  # Docs restarts and migrations with THIS pipeline's code — inside the other
  # pipeline's tenant, and raced its own deploy: pipeline 2337 died on
  # `configmaps "health-sidecar-scripts" already exists` when 2336 created the
  # same object in the same second. A tenant gets prepped by the pipeline
  # that leases it. Guarded by scripts/tests/test-ci-leased-tenant-only.sh.
fi

if [[ ${#TENANTS[@]} -eq 0 ]]; then
  echo "ERROR: No tenants to deploy"
  exit 1
fi

# ── Keep tenant lease alive during deploy ─────────────────────────
# Renew the pool lease every 120s so it survives a 10+ min deploy. If the
# --bringup-only step already started the renewal loop, this is a no-op.
_start_lease_renewal

# ── Acquire deploy lock (prod only) ──────────────────────────────
# Valkey-based locking to prevent concurrent deploys to the same env.
#
# Dev doesn't need this: the pool lease system ensures each PR deploys
# a different tenant, and deploy_infra (helmfile sync) is idempotent.
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
    # Only delete the lock if we still hold it: if our TTL lapsed mid-deploy and
    # another pipeline acquired it, an unconditional DEL would drop THEIR lock.
    vcli_del_if "$LOCK_KEY" "$CI_PIPELINE_NUMBER" >/dev/null 2>&1 || true
  fi
}

_DEPLOY_LOCK_ACQUIRED=""

if [[ "$ALL_TENANTS" == "true" ]]; then
  # Prod: acquire deploy lock with last-writer-wins semantics
  : "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required for deploy locking}"
  # Every lock value on this path is derived from the pipeline number, and an
  # empty-but-set value passes `set -u` and every downstream check. Assert it
  # here rather than discovering it inside an EXIT trap.
  : "${CI_PIPELINE_NUMBER:?CI_PIPELINE_NUMBER is required for deploy locking}"
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
    # Lock is held — check who holds it
    HOLDER=$($_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
      GET "$LOCK_KEY" 2>/dev/null || echo "unknown")
    echo "Deploy lock held by pipeline #$HOLDER"

    # Self-deadlock: if we already hold the lock (e.g. a parallel workflow in
    # the same pipeline set it, or a restarted step left it), just re-acquire.
    if [[ "$HOLDER" == "$CI_PIPELINE_NUMBER" ]]; then
      echo "Lock holder is this pipeline (#$CI_PIPELINE_NUMBER) — re-acquiring"
      # Guarded refresh, and the result is CHECKED. The previous unconditional
      # `SET … XX` discarded its result and announced success regardless: if the
      # key had expired in the window, XX is a no-op and we would deploy
      # PRODUCTION holding no lock at all, leaving another pipeline free to
      # acquire and deploy concurrently. Same bug family as #647, same key.
      if [[ "$(vcli_renew_if "$LOCK_KEY" "$CI_PIPELINE_NUMBER" "$LOCK_TTL" 2>/dev/null || echo 0)" == "1" ]]; then
        _DEPLOY_LOCK_ACQUIRED=1
        echo "Acquired deploy lock (pipeline #$CI_PIPELINE_NUMBER)"
      else
        echo "ERROR: deploy lock for #$CI_PIPELINE_NUMBER vanished or changed hands" >&2
        echo "       while re-acquiring. Refusing to deploy without holding it." >&2
        exit 1
      fi
    else

    $_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
      SET "$PENDING_KEY" "$CI_PIPELINE_NUMBER" EX "$MAX_WAIT" >/dev/null 2>&1
    echo "Registered as pending deploy (pipeline #$CI_PIPELINE_NUMBER)"

    # Wait for lock to be released
    while true; do
      sleep 30
      ELAPSED=$((ELAPSED + 30))
      if (( ELAPSED >= MAX_WAIT )); then
        echo "ERROR: Could not acquire deploy lock after ${MAX_WAIT}s"
        exit 1
      fi

      # Check if we've already been superseded before even trying the lock
      CURRENT_PENDING=$($_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
        GET "$PENDING_KEY" 2>/dev/null || echo "")
      if [[ -n "$CURRENT_PENDING" ]] && [[ "$CURRENT_PENDING" != "$CI_PIPELINE_NUMBER" ]]; then
        echo "Superseded by pipeline #$CURRENT_PENDING while waiting — skipping deploy"
        echo "=== Deploy skipped (newer merge will deploy) ==="
        exit 0
      fi

      # Try to acquire the lock
      RESULT=$($_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
        SET "$LOCK_KEY" "$CI_PIPELINE_NUMBER" NX EX "$LOCK_TTL" 2>/dev/null || true)
      if [[ "$RESULT" == "OK" ]]; then
        # Got the lock — only proceed if we're still the pending one.
        # If pending key is empty (someone else already deployed and cleared it)
        # or someone else (a newer pipeline overwrote us), we're stale — abort.
        CURRENT_PENDING=$($_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
          GET "$PENDING_KEY" 2>/dev/null || echo "")
        if [[ "$CURRENT_PENDING" != "$CI_PIPELINE_NUMBER" ]]; then
          # We've been superseded — release the lock we just took, and only
          # that one.
          vcli_del_if "$LOCK_KEY" "$CI_PIPELINE_NUMBER" >/dev/null 2>&1 || true
          echo "Superseded (pending=${CURRENT_PENDING:-<empty>}, us=$CI_PIPELINE_NUMBER) — skipping deploy"
          echo "=== Deploy skipped (newer merge will deploy) ==="
          exit 0
        fi
        # We're the latest — clear OUR pending marker, compare-and-delete.
        # Unconditional DEL here erases a newer pipeline's claim if one landed
        # between the read above and this line: that pipeline then acquires the
        # lock, reads pending as empty, and aborts as "Superseded" — so its
        # merged commit never reaches prod, with a green pipeline. Note :370
        # treats an empty pending as "keep going" while :385 treats it as
        # "abort", which is what makes the erasure fatal rather than benign.
        vcli_del_if "$PENDING_KEY" "$CI_PIPELINE_NUMBER" >/dev/null 2>&1 || true
        _DEPLOY_LOCK_ACQUIRED=1
        echo "Acquired deploy lock (pipeline #$CI_PIPELINE_NUMBER)"
        break
      fi

      HOLDER=$($_CLI -h 127.0.0.1 -a "$CI_VALKEY_PASSWORD" --no-auth-warning \
        GET "$LOCK_KEY" 2>/dev/null || echo "unknown")

      # Check if the lock holder pipeline is still alive
      HOLDER_PIPELINE=$(_extract_pipeline_number "$HOLDER")
      if ! _pipeline_is_alive "$HOLDER_PIPELINE"; then
        echo "Deploy lock held by pipeline #${HOLDER_PIPELINE} which is no longer running — force-acquiring"
        # Compare-and-delete against the holder we read. This is the PROD deploy
        # lock: two pipelines both clearing the same dead holder would both
        # proceed to deploy production concurrently (#647).
        vcli_del_if "$LOCK_KEY" "$HOLDER" >/dev/null 2>&1 || true
        continue  # retry acquire immediately
      fi

      echo "Deploy lock held by #$HOLDER, waiting... ($ELAPSED/${MAX_WAIT}s)"
    done

    fi  # end self-deadlock check
  fi
else
  # Dev: acquire infra lock to prevent concurrent shared infra deploys
  # and to wait for any running e2e tests to finish.
  : "${CI_VALKEY_PASSWORD:?CI_VALKEY_PASSWORD is required for infra locking}"
  "$REPO_ROOT/ci/scripts/ci-infra-lock.sh" acquire
  _INFRA_LOCK_ACQUIRED=1
fi

_release_infra_lock() {
  if [[ -n "${_INFRA_LOCK_ACQUIRED:-}" ]]; then
    "$REPO_ROOT/ci/scripts/ci-infra-lock.sh" release || true
    _INFRA_LOCK_ACQUIRED=""
  fi
}

trap '_release_deploy_lock; _release_infra_lock; _cleanup' EXIT

echo ""
echo "=== Running deploy_infra -e $MT_ENV ==="
"$REPO_ROOT/scripts/deploy_infra" -e "$MT_ENV"

echo ""
echo "=== deploy_infra complete ==="

# Prove the alert delivery path right after the infra deploy: a synthetic
# alert must reach Matrix through the bridge (Alertmanager + bridge counters).
# prod-eu ran eleven weeks with undeliverable alerts and nothing was red;
# this turns that into a RED pipeline. It must not, however, block the tenant
# deploys below: the alertbot posts to a Synapse that create_env itself
# deploys, so a Matrix outage would otherwise wedge the very hotfix that
# restores Matrix. The verdict is captured here and enforced at the end, after
# every tenant has been deployed.
echo ""
echo "=== Alerting self-test (scripts/verify-alerting -e $MT_ENV) ==="
ALERT_SELFTEST_RC=0
"$REPO_ROOT/scripts/verify-alerting" -e "$MT_ENV" || ALERT_SELFTEST_RC=$?
if [[ "$ALERT_SELFTEST_RC" -ne 0 ]]; then
  echo "ERROR: alerting self-test FAILED (rc=$ALERT_SELFTEST_RC) — continuing with tenant deploys; this run will exit non-zero at the end"
fi

# Release infra lock early — create_env is tenant-scoped, doesn't need it.
# This lets the other pipeline's deploy_infra proceed while we run create_env.
_release_infra_lock

# ── Deploy tenant(s) ─────────────────────────────────────────────
CREATE_ENV_EXTRA_ARGS=""
if [[ "$PREP_ONLY" == "true" ]]; then
  CREATE_ENV_EXTRA_ARGS="--prep-only"
fi

FAILED_TENANTS=()
for tenant in "${TENANTS[@]}"; do
  echo ""
  echo "=== Running create_env -e $MT_ENV -t $tenant ${CREATE_ENV_EXTRA_ARGS} ==="
  if "$REPO_ROOT/scripts/create_env" -e "$MT_ENV" -t "$tenant" $CREATE_ENV_EXTRA_ARGS; then
    echo "=== Tenant $tenant deployed successfully ==="
  else
    echo "=== FAILED: Tenant $tenant deploy failed ==="
    FAILED_TENANTS+=("$tenant")
    # Continue deploying remaining tenants (prod multi-tenant resilience)
    if [[ "$ALL_TENANTS" != "true" ]] && [[ "$PREP_ONLY" != "true" ]]; then
      exit 1  # For dev app deploy (single tenant), fail immediately
              # For prep-only, continue so infra is created for remaining tenants
    fi
  fi
done

echo ""
if [[ ${#FAILED_TENANTS[@]} -gt 0 ]]; then
  echo "ERROR: Failed tenants: ${FAILED_TENANTS[*]}"
  exit 1
fi
if [[ "${ALERT_SELFTEST_RC:-0}" -ne 0 ]]; then
  echo "ERROR: alerting self-test failed earlier (rc=$ALERT_SELFTEST_RC) — alert delivery on $MT_ENV is NOT proven; tenants were deployed anyway so a fix can land"
  exit 1
fi

echo "=== CI Deploy complete: env=$MT_ENV tenants=${TENANTS[*]} ==="
