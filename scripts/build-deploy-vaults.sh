#!/usr/bin/env bash
set -euo pipefail

# Build Ansible Vault-encrypted deploy archives for CI.
#
# Assembles kubeconfigs, terraform outputs, and tenant secrets into per-env
# tarballs, encrypts them with ansible-vault, and places the encrypted files
# in config/platform/ci/ for provisioning to the CI host.
#
# Per-environment vault passwords
# ───────────────────────────────
# dev uses its OWN ansible-vault password, separate from prod/prod-eu, so the
# dev vault password can be shared with a contributor without exposing prod
# secrets. The dev password unlocks ONLY deploy-vault-dev.vault; the
# prod/prod-eu vaults stay under the shared operator password.
#
#   Precedence for the password (highest first):
#     1. $MT_VAULT_PASSWORD_FILE  — path to a file containing the password
#     2. $MT_VAULT_PASSWORD       — the password value itself
#     3. LastPass                 — dev: $LPASS_DEV_VAULT_ENTRY,
#                                   prod/prod-eu: $LPASS_VAULT_ENTRY
#
# Usage:
#   ./scripts/build-deploy-vaults.sh                 # Full build, all envs
#   ./scripts/build-deploy-vaults.sh dev             # Full build, dev only
#   ./scripts/build-deploy-vaults.sh prod            # Full build, prod only
#
#   # Patch mode — update ONLY the named tenant secret(s) inside an existing
#   # vault, preserving kubeconfig / terraform-outputs / tf-state untouched.
#   # No LastPass needed; supply the dev password via MT_VAULT_PASSWORD.
#   MT_VAULT_PASSWORD=<dev-pw> \
#     ./scripts/build-deploy-vaults.sh dev --update-secrets --tenant acme
#   ... --tenant acme --tenant beta   # repeatable; at least one required
#
# Prerequisites:
#   - ansible-vault, tar installed
#   - Full build: kubeconfig.<env>.yaml at repo root,
#                 config/platform/infra/terraform-outputs.<env>.env,
#                 config/tenants/<tenant>/<env>.secrets.yaml,
#                 and a password source (LastPass login or MT_VAULT_PASSWORD*)
#   - Patch mode: an existing config/platform/ci/deploy-vault-<env>.vault,
#                 the matching vault password, and the local tenant secrets

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[vault]${NC} $1"; }
print_success() { echo -e "${GREEN}[vault]${NC} $1"; }
print_error() { echo -e "${RED}[vault]${NC} $1" >&2; }

# ── LastPass entry for the prod / prod-eu (shared) vault password ──
LPASS_VAULT_ENTRY="7375668101991863677"

# ── LastPass entry for the dev-only vault password ────────────────
# Separate from the shared password above so the dev vault can be re-keyed
# and its password handed to a contributor without granting prod/prod-eu
# access. Create this LastPass note with a fresh random password before the
# first dev re-key (see DEV_VAULT_ACCESS.md).
LPASS_DEV_VAULT_ENTRY="mothertree-dev-vault-password"

# ── LastPass entry for the phase1-dev Terraform-state bucket creds ─
# Created during the phase1-dev migration (see phase1-dev/MIGRATION.md).
# The entry stores the access key in the Username field and the secret key
# in the Password field (standard lpass credential format).
# Dev only — CI doesn't run terraform for prod or prod-eu.
LPASS_TF_STATE_ENTRY="mothertree-tf-state-dev-s3-credentials"

# ── Parse args ────────────────────────────────────────────────────
ENV_ARG=""
UPDATE_SECRETS=false
PATCH_TENANTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --update-secrets) UPDATE_SECRETS=true ;;
    --tenant)
      shift
      [[ -n "${1:-}" ]] || { print_error "--tenant requires a tenant name"; exit 1; }
      PATCH_TENANTS+=("$1")
      ;;
    --tenant=*) PATCH_TENANTS+=("${1#*=}") ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) print_error "Unknown option: $1"; exit 1 ;;
    *)
      if [[ -n "$ENV_ARG" ]]; then
        print_error "Unexpected argument: $1 (env already set to '$ENV_ARG')"
        exit 1
      fi
      ENV_ARG="$1"
      ;;
  esac
  shift
done

# ── Validate always-required prerequisites ────────────────────────
for cmd in ansible-vault tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    print_error "$cmd is required but not found"
    exit 1
  fi
done

OUTPUT_DIR="$REPO_ROOT/config/platform/ci"
if [[ ! -d "$OUTPUT_DIR" ]]; then
  print_error "Output directory not found: $OUTPUT_DIR"
  exit 1
fi

TENANTS_DIR="$REPO_ROOT/config/tenants"
INFRA_DIR="$REPO_ROOT/config/platform/infra"

# ── LastPass helpers (only required when LastPass is the password source) ──
_require_lpass() {
  if ! command -v lpass >/dev/null 2>&1; then
    print_error "lpass is required to source the vault password from LastPass."
    print_error "Either log in to LastPass, or pass MT_VAULT_PASSWORD / MT_VAULT_PASSWORD_FILE."
    exit 1
  fi
  if ! lpass status -q 2>/dev/null; then
    print_error "Not logged in to LastPass. Run: lpass login <email>"
    print_error "(or pass the password via MT_VAULT_PASSWORD / MT_VAULT_PASSWORD_FILE)"
    exit 1
  fi
}

# Resolve the ansible-vault password for the given env, honouring the
# MT_VAULT_PASSWORD_FILE > MT_VAULT_PASSWORD > LastPass precedence. Echoes the
# password to stdout (capture with $(...)).
_resolve_vault_password() {
  local env="$1"
  local override_set=false
  [[ -n "${MT_VAULT_PASSWORD_FILE:-}" || -n "${MT_VAULT_PASSWORD:-}" ]] && override_set=true

  # The direct-password override (MT_VAULT_PASSWORD[_FILE]) is DEV ONLY — it is
  # the contributor patch-mode path. prod/prod-eu MUST be encrypted with the
  # shared operator password from LastPass, so refuse the override there rather
  # than silently honour it. This stops a stray MT_VAULT_PASSWORD (e.g. a dev
  # password left exported in the shell) from re-encrypting prod/prod-eu under
  # the wrong key — which would let the dev password decrypt the prod vault.
  if [[ "$env" != "dev" && "$override_set" == "true" ]]; then
    print_error "MT_VAULT_PASSWORD / MT_VAULT_PASSWORD_FILE is set, but env '$env' must use the shared operator vault password from LastPass."
    print_error "The direct-password override applies to 'dev' only. Unset it, or build 'dev' explicitly."
    exit 1
  fi

  if [[ "$env" == "dev" ]]; then
    if [[ -n "${MT_VAULT_PASSWORD_FILE:-}" ]]; then
      [[ -f "$MT_VAULT_PASSWORD_FILE" ]] || {
        print_error "MT_VAULT_PASSWORD_FILE not found: $MT_VAULT_PASSWORD_FILE"; exit 1; }
      # First line only, matching how ansible-vault reads a password file.
      head -n1 "$MT_VAULT_PASSWORD_FILE"
      return 0
    fi
    if [[ -n "${MT_VAULT_PASSWORD:-}" ]]; then
      printf '%s\n' "$MT_VAULT_PASSWORD"
      return 0
    fi
  fi
  _require_lpass
  local entry
  if [[ "$env" == "dev" ]]; then
    entry="$LPASS_DEV_VAULT_ENTRY"
  else
    entry="$LPASS_VAULT_ENTRY"
  fi
  local pw
  pw=$(lpass show --note "$entry" 2>/dev/null)
  if [[ -z "$pw" ]]; then
    print_error "Failed to fetch vault password from LastPass entry: $entry"
    if [[ "$env" == "dev" ]]; then
      print_error "Create the dev vault-password note (see DEV_VAULT_ACCESS.md), or pass MT_VAULT_PASSWORD."
    fi
    exit 1
  fi
  printf '%s\n' "$pw"
}

# ═══════════════════════════════════════════════════════════════════
#  Patch mode — update only the named tenant secret(s) in an existing
#  vault, leaving infra artifacts (kubeconfig, terraform-outputs,
#  tf-state-creds) exactly as they are. Lets a contributor add/update
#  tenant secrets with ONLY the dev vault password — no LastPass, no
#  kubeconfig, no terraform outputs, no tf-state credentials.
# ═══════════════════════════════════════════════════════════════════
if [[ "$UPDATE_SECRETS" == "true" ]]; then
  : "${ENV_ARG:?--update-secrets requires an explicit env (e.g. dev)}"
  env="$ENV_ARG"

  if [[ ${#PATCH_TENANTS[@]} -eq 0 ]]; then
    print_error "--update-secrets requires at least one --tenant <name>."
    print_error "This scopes the update to exactly the tenants you intend to change,"
    print_error "so an unrelated stale local secrets file can't silently overwrite the vault."
    exit 1
  fi

  VAULT_FILE="$OUTPUT_DIR/deploy-vault-${env}.vault"
  if [[ ! -f "$VAULT_FILE" ]]; then
    print_error "Existing vault not found: $VAULT_FILE"
    print_error "Patch mode updates an existing vault. Run a full build first (operator)."
    exit 1
  fi

  print_status "Patch mode: updating tenant secret(s) in $(basename "$VAULT_FILE")"
  print_status "  Tenants: ${PATCH_TENANTS[*]}"

  VAULT_PASSWORD=$(_resolve_vault_password "$env")

  STAGING=$(mktemp -d /tmp/mt-vault-patch-XXXXXX)
  DEC_TAR=$(mktemp -u /tmp/mt-vault-patch-tar-XXXXXX.tar.gz)
  NEWTAR=""
  # NEWTAR is the plaintext re-tar of all dev secrets — track it so a kill or a
  # failed encrypt can't orphan it in /tmp (it's a sibling of STAGING, not inside
  # it, so `rm -rf "$STAGING"` would not catch it).
  _patch_cleanup() { rm -rf "$STAGING" "$DEC_TAR" ${NEWTAR:+"$NEWTAR"}; }
  trap _patch_cleanup EXIT

  # Decrypt the existing vault into the staging dir.
  print_status "  Decrypting existing vault..."
  if ! ansible-vault decrypt "$VAULT_FILE" \
        --vault-password-file <(printf '%s\n' "$VAULT_PASSWORD") \
        --output "$DEC_TAR" 2>/dev/null; then
    print_error "Failed to decrypt $VAULT_FILE — wrong vault password?"
    exit 1
  fi
  tar xzf "$DEC_TAR" -C "$STAGING"
  rm -f "$DEC_TAR"

  if [[ ! -d "$STAGING/tenants" ]]; then
    print_error "Decrypted vault has no tenants/ directory — unexpected layout, aborting."
    exit 1
  fi

  # Overlay ONLY the named tenants' local secrets. Each must exist locally.
  for tenant in "${PATCH_TENANTS[@]}"; do
    src="$TENANTS_DIR/$tenant/${env}.secrets.yaml"
    if [[ ! -f "$src" ]]; then
      print_error "Local secrets file not found: $src"
      print_error "Edit config/tenants/$tenant/${env}.secrets.yaml before patching."
      exit 1
    fi
    mkdir -p "$STAGING/tenants/$tenant"
    cp "$src" "$STAGING/tenants/$tenant/${env}.secrets.yaml"
    print_status "  Updated tenants/$tenant/${env}.secrets.yaml"
  done

  # Re-tar and re-encrypt with the SAME password (overwrites the vault).
  # umask 077 so the plaintext tarball is 0600, not world-readable, for the
  # brief window before it's encrypted and removed.
  NEWTAR="$STAGING.tar.gz"
  ( umask 077; tar czf "$NEWTAR" -C "$STAGING" . )
  print_status "  Re-encrypting → $VAULT_FILE"
  ansible-vault encrypt "$NEWTAR" \
    --vault-password-file <(printf '%s\n' "$VAULT_PASSWORD") \
    --output "$VAULT_FILE"
  rm -f "$NEWTAR"

  VAULT_SIZE=$(du -h "$VAULT_FILE" | cut -f1)
  print_success "Patched $VAULT_FILE ($VAULT_SIZE; tenants: ${PATCH_TENANTS[*]})"
  echo ""
  echo "Next steps:"
  echo "  1. Commit the updated vault file in config/platform/ci/"
  echo "  2. Open a PR — CI deploys the change to dev."
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════
#  Full build mode — rebuild the entire vault for each environment.
# ═══════════════════════════════════════════════════════════════════
ENVS=("dev" "prod" "prod-eu")
if [[ -n "$ENV_ARG" ]]; then
  ENVS=("$ENV_ARG")
fi

# Guard: the direct-password override is dev-only. Refuse it up-front if the
# build set includes any non-dev env, BEFORE any vault is (re)written — so a
# stray MT_VAULT_PASSWORD can't re-key dev with it and then fail partway, or
# silently re-key prod/prod-eu.
if [[ -n "${MT_VAULT_PASSWORD:-}${MT_VAULT_PASSWORD_FILE:-}" ]]; then
  for _e in "${ENVS[@]}"; do
    if [[ "$_e" != "dev" ]]; then
      print_error "MT_VAULT_PASSWORD / MT_VAULT_PASSWORD_FILE is set, but this build includes non-dev env '$_e'."
      print_error "The direct-password override applies to 'dev' only. Unset it, or build 'dev' explicitly."
      exit 1
    fi
  done
fi

CLEANUP_DIRS=()
_cleanup_all() {
  for d in "${CLEANUP_DIRS[@]}"; do
    rm -rf "$d"
  done
}
trap _cleanup_all EXIT

for env in "${ENVS[@]}"; do
  print_status "Building deploy vault for env=$env..."

  # Resolve the password for THIS env (dev uses its own password).
  VAULT_PASSWORD=$(_resolve_vault_password "$env")

  STAGING=$(mktemp -d /tmp/mt-vault-build-XXXXXX)
  CLEANUP_DIRS+=("$STAGING")

  ERRORS=()

  # 1. Kubeconfig
  KUBECONFIG_SRC="$REPO_ROOT/kubeconfig.${env}.yaml"
  if [[ -f "$KUBECONFIG_SRC" ]]; then
    cp "$KUBECONFIG_SRC" "$STAGING/kubeconfig.yaml"
    print_status "  Added kubeconfig.yaml"
  else
    ERRORS+=("Kubeconfig not found: $KUBECONFIG_SRC")
  fi

  # 2. Terraform outputs
  TF_OUTPUTS_SRC="$INFRA_DIR/terraform-outputs.${env}.env"
  if [[ -f "$TF_OUTPUTS_SRC" ]]; then
    cp "$TF_OUTPUTS_SRC" "$STAGING/terraform-outputs.env"
    print_status "  Added terraform-outputs.env"
  else
    ERRORS+=("Terraform outputs not found: $TF_OUTPUTS_SRC")
  fi

  # 3. Phase1-dev Terraform-state bucket creds (dev only).
  # CI's bring-up step runs `terraform apply` against phase1-dev's S3 backend
  # (bucket `mothertree-tf-state-dev`). The scoped access key for that bucket
  # is stored in LastPass and pulled into the vault on every rebuild.
  if [[ "$env" == "dev" ]]; then
    _require_lpass
    print_status "  Fetching phase1-dev tf-state creds from LastPass ($LPASS_TF_STATE_ENTRY)..."
    TF_STATE_AK=$(lpass show --username "$LPASS_TF_STATE_ENTRY" 2>/dev/null || true)
    TF_STATE_SK=$(lpass show --password "$LPASS_TF_STATE_ENTRY" 2>/dev/null || true)
    if [[ -z "$TF_STATE_AK" || -z "$TF_STATE_SK" ]]; then
      ERRORS+=("LastPass entry '$LPASS_TF_STATE_ENTRY' is missing Username or Password (access/secret key). See phase1-dev/MIGRATION.md for setup.")
    else
      # printf with %s avoids any shell interpolation on the secret values —
      # an unquoted heredoc would expand `$`/backticks/backslashes if the
      # keys ever contained those characters (Linode keys are alphanumeric
      # in practice, but defending against the future change is cheap).
      umask 077
      {
          printf 'AWS_ACCESS_KEY_ID=%s\n' "$TF_STATE_AK"
          printf 'AWS_SECRET_ACCESS_KEY=%s\n' "$TF_STATE_SK"
      } > "$STAGING/tf-state-creds.env"
      umask 022
      print_status "  Added tf-state-creds.env (phase1-dev backend)"
    fi
  fi

  # 4. Tenant secrets (config files come from git submodules, not the vault)
  TENANT_COUNT=0
  for tenant_dir in "$TENANTS_DIR"/*/; do
    [[ -d "$tenant_dir" ]] || continue
    tenant=$(basename "$tenant_dir")
    [[ "$tenant" == ".example" ]] && continue

    secrets_file="$tenant_dir/${env}.secrets.yaml"
    if [[ -f "$secrets_file" ]]; then
      mkdir -p "$STAGING/tenants/$tenant"
      cp "$secrets_file" "$STAGING/tenants/$tenant/${env}.secrets.yaml"
      TENANT_COUNT=$((TENANT_COUNT + 1))
      print_status "  Added tenants/$tenant/${env}.secrets.yaml"
    else
      print_status "  Skipping $tenant (no ${env}.secrets.yaml)"
    fi
  done

  # Check for fatal errors
  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    for err in "${ERRORS[@]}"; do
      print_error "  $err"
    done
    print_error "Cannot build vault for $env — missing required files"
    rm -rf "$STAGING"
    exit 1
  fi

  if [[ $TENANT_COUNT -eq 0 ]]; then
    print_error "No tenant secrets found for env=$env"
    rm -rf "$STAGING"
    exit 1
  fi

  # 5. Create tarball. Track it for cleanup (it's a sibling of STAGING, not
  # inside it) and create it 0600 via umask so the plaintext secrets aren't
  # world-readable in the window before encryption.
  TARBALL="$STAGING.tar.gz"
  CLEANUP_DIRS+=("$TARBALL")
  ( umask 077; tar czf "$TARBALL" -C "$STAGING" . )
  rm -rf "$STAGING"

  # 6. Encrypt with ansible-vault
  VAULT_FILE="$OUTPUT_DIR/deploy-vault-${env}.vault"
  print_status "  Encrypting → $VAULT_FILE"

  ansible-vault encrypt "$TARBALL" \
    --vault-password-file <(printf '%s\n' "$VAULT_PASSWORD") \
    --output "$VAULT_FILE"
  rm -f "$TARBALL"

  VAULT_SIZE=$(du -h "$VAULT_FILE" | cut -f1)
  print_success "  Created $VAULT_FILE ($VAULT_SIZE, $TENANT_COUNT tenant(s))"
done

echo ""
print_success "Deploy vaults built successfully."
echo ""
echo "Next steps:"
echo "  1. Commit the vault files in config/platform/ci/"
echo "  2. Re-provision the CI box: ./ci/scripts/provision-ci.sh --ansible-only"
echo "  3. dev uses its own vault password (LastPass: $LPASS_DEV_VAULT_ENTRY) —"
echo "     set the 'deploy_vault_password_dev' Ansible var so CI can decrypt it."
echo "     prod/prod-eu use the shared 'deploy_vault_password' Woodpecker secret."
