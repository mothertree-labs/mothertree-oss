#!/usr/bin/env bash
set -euo pipefail

# Build Ansible Vault-encrypted deploy archives for CI.
#
# Assembles kubeconfigs, terraform outputs, and tenant secrets into per-env
# tarballs, encrypts them with ansible-vault, and places the encrypted files
# in config/platform/ci/ for provisioning to the CI host.
#
# Usage:
#   ./scripts/build-deploy-vaults.sh              # Build all envs
#   ./scripts/build-deploy-vaults.sh dev           # Build dev only
#   ./scripts/build-deploy-vaults.sh prod          # Build prod only
#
# Prerequisites:
#   - lpass CLI authenticated (lpass status)
#   - ansible-vault installed
#   - kubeconfig.<env>.yaml files at repo root
#   - config/platform/infra/terraform-outputs.<env>.env files
#   - config/tenants/<tenant>/<env>.secrets.yaml files

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[vault]${NC} $1"; }
print_success() { echo -e "${GREEN}[vault]${NC} $1"; }
print_error() { echo -e "${RED}[vault]${NC} $1" >&2; }

# ── LastPass entry for the vault password ─────────────────────────
LPASS_VAULT_ENTRY="7375668101991863677"

# ── Validate prerequisites ────────────────────────────────────────
for cmd in ansible-vault lpass tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    print_error "$cmd is required but not found"
    exit 1
  fi
done

if ! lpass status -q 2>/dev/null; then
  print_error "Not logged in to LastPass. Run: lpass login <email>"
  exit 1
fi

# ── Fetch vault password ──────────────────────────────────────────
print_status "Fetching vault password from LastPass..."
VAULT_PASSWORD=$(lpass show --note "$LPASS_VAULT_ENTRY" 2>/dev/null)
if [[ -z "$VAULT_PASSWORD" ]]; then
  print_error "Failed to fetch vault password from LastPass entry: $LPASS_VAULT_ENTRY"
  exit 1
fi

# ── Determine which envs to build ─────────────────────────────────
ENVS=("${1:-dev}" "${1:-prod}")
if [[ -n "${1:-}" ]]; then
  ENVS=("$1")
fi

OUTPUT_DIR="$REPO_ROOT/config/platform/ci"
if [[ ! -d "$OUTPUT_DIR" ]]; then
  print_error "Output directory not found: $OUTPUT_DIR"
  exit 1
fi

TENANTS_DIR="$REPO_ROOT/config/tenants"
INFRA_DIR="$REPO_ROOT/config/platform/infra"

# ── Build vault for each environment ──────────────────────────────
CLEANUP_DIRS=()
_cleanup_all() {
  for d in "${CLEANUP_DIRS[@]}"; do
    rm -rf "$d"
  done
}
trap _cleanup_all EXIT

for env in "${ENVS[@]}"; do
  print_status "Building deploy vault for env=$env..."

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

  # 3. Tenant secrets (config files come from git submodules, not the vault)
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

  # 4. Create tarball
  TARBALL="$STAGING.tar.gz"
  tar czf "$TARBALL" -C "$STAGING" .
  rm -rf "$STAGING"

  # 5. Encrypt with ansible-vault
  VAULT_FILE="$OUTPUT_DIR/deploy-vault-${env}.vault"
  print_status "  Encrypting → $VAULT_FILE"

  ansible-vault encrypt "$TARBALL" \
    --vault-password-file <(echo "$VAULT_PASSWORD") \
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
echo "  3. Add 'deploy_vault_password' secret in Woodpecker UI (same password as LastPass entry)"
