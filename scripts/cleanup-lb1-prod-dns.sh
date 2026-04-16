#!/bin/bash

# One-shot cleanup: delete orphaned `lb1.prod.<domain>` A records after
# migrating prod to `lb2.prod`. Idempotent — safe to re-run.
#
# NOTE: lb1.prod.<domain> is now an intentional CNAME → lb1.prod-eu.<domain>
# (managed by manage-dns.sh). This script only deletes type=A records, so
# it will not touch the CNAME. Migration is complete; this script is a no-op.
#
# Originally deleted:
#   - lb1.prod.<INFRA_DOMAIN>            (the old shared infra A record)
#   - lb1.prod.<tenant_domain>           (per prod tenant A record)
#
# Usage:
#   ./scripts/cleanup-lb1-prod-dns.sh -e prod [--dry-run]
#
# Only operates on MT_ENV=prod. Run AFTER:
#   1. `manage_infra --dns -e prod` has created the new lb2.prod record
#   2. `create_env -e prod -t <tenant>` has been re-run for every prod tenant
#   3. Enough time (≥ 2x TTL) has passed for caches to drain

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  echo "Usage: $0 -e prod [--dry-run]"
  echo ""
  echo "One-shot cleanup of orphaned lb1.prod.* A records after lb2 migration."
  echo "Idempotent. Only operates on MT_ENV=prod."
}

DRY_RUN="false"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN="true" ;;
  esac
done

mt_parse_args "$@"
mt_require_env

if [ "$MT_ENV" != "prod" ]; then
  print_error "This cleanup script only runs against prod (MT_ENV=$MT_ENV)"
  exit 1
fi

mt_require_commands curl jq yq

if [ -f "$REPO_ROOT/secrets.tfvars.env" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/secrets.tfvars.env"
elif [ -f "$REPO_ROOT/secrets.${MT_ENV}.tfvars.env" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/secrets.${MT_ENV}.tfvars.env"
fi

if [ -z "${TF_VAR_cloudflare_api_token:-}" ]; then
  print_error "TF_VAR_cloudflare_api_token not set"
  exit 1
fi

source "${REPO_ROOT}/scripts/lib/dns.sh"
source "${REPO_ROOT}/scripts/lib/paths.sh"
_mt_resolve_tenants_dir

# Wrapper to honour --dry-run
_delete_or_log() {
  local name="$1" type="$2"
  if [ "$DRY_RUN" = "true" ]; then
    print_status "[dry-run] Would delete: $name ($type)"
    return 0
  fi
  delete_dns_record "$name" "$type"
}

# =============================================================================
# Step 1: delete lb1.prod.<INFRA_DOMAIN> from the infra zone
# =============================================================================
(
  source "${REPO_ROOT}/scripts/lib/infra-config.sh"
  mt_load_infra_config

  if [ -z "${INFRA_DOMAIN:-}" ]; then
    print_error "INFRA_DOMAIN not set after loading infra config"
    exit 1
  fi
  if [ -z "${TF_VAR_cloudflare_zone_id:-}" ]; then
    print_error "TF_VAR_cloudflare_zone_id not set from infra config"
    exit 1
  fi

  print_status "=== Infra record: lb1.prod.${INFRA_DOMAIN} (zone=${TF_VAR_cloudflare_zone_id}) ==="
  _delete_or_log "lb1.prod.${INFRA_DOMAIN}" "A"
)

# =============================================================================
# Step 2: delete lb1.prod.<tenant_domain> for every prod tenant (in subshells
# so each tenant's config/zone_id is loaded cleanly)
# =============================================================================
for tenant_dir in "$MT_TENANTS_DIR"/*/; do
  [ -d "$tenant_dir" ] || continue
  tenant_name=$(basename "$tenant_dir")
  config_file="$tenant_dir/${MT_ENV}.config.yaml"
  [ -f "$config_file" ] || continue

  # Prod tenants have empty/null env_dns_label
  env_label=$(yq '.dns.env_dns_label // ""' "$config_file")
  if [ -n "$env_label" ] && [ "$env_label" != "null" ]; then
    continue
  fi

  (
    export MT_TENANT="$tenant_name"
    source "${REPO_ROOT}/scripts/lib/config.sh"
    mt_load_tenant_config >/dev/null

    if [ -z "${TENANT_DOMAIN:-}" ]; then
      print_warning "Skipping tenant $tenant_name — TENANT_DOMAIN empty"
      exit 0
    fi
    if [ -z "${TF_VAR_cloudflare_zone_id:-}" ]; then
      print_warning "Skipping tenant $tenant_name — no cloudflare zone_id"
      exit 0
    fi

    print_status "=== Tenant $tenant_name: lb1.prod.${TENANT_DOMAIN} (zone=${TF_VAR_cloudflare_zone_id}) ==="
    _delete_or_log "lb1.prod.${TENANT_DOMAIN}" "A"
  )
done

print_success "Cleanup complete"
