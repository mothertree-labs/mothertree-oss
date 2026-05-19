#!/bin/bash

# Rotate Tailscale pre-auth keys on Headscale servers
#
# Creates new tagged pre-auth keys on the Headscale coordination server,
# updates the secrets YAML file, and optionally patches K8s secrets and
# rebuilds deploy vaults.
#
# Usage:
#   ./scripts/rotate-tailscale-keys.sh -e <env> [options]
#
# Options:
#   --component=<name>   Component to rotate: pgbouncer, metrics, or all (default: all)
#   --apply-now          Patch K8s secrets and restart pods immediately
#   --rebuild-vaults     Rebuild CI deploy vaults after rotation
#   --expiration=<dur>   Key expiration (default: 8760h = 1 year)
#
# Examples:
#   ./scripts/rotate-tailscale-keys.sh -e dev
#   ./scripts/rotate-tailscale-keys.sh -e prod --component=pgbouncer --apply-now
#   ./scripts/rotate-tailscale-keys.sh -e dev --apply-now --rebuild-vaults

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  echo "Usage: $0 -e <env> [--component=<pgbouncer|metrics|all>] [--apply-now] [--rebuild-vaults]"
  echo ""
  echo "Rotate Tailscale pre-auth keys on the Headscale server."
  echo ""
  echo "Options:"
  echo "  -e <env>              Environment (e.g., dev, prod, prod-eu)"
  echo "  --component=<name>    Component: pgbouncer, metrics, or all (default: all)"
  echo "  --apply-now           Patch K8s secrets and restart pods immediately"
  echo "  --rebuild-vaults      Rebuild CI deploy vaults after rotation"
  echo "  --expiration=<dur>    Key expiration duration (default: 8760h = 1 year)"
  echo "  -h, --help            Show this help"
}

mt_parse_args "$@"
mt_require_env

# Parse script-specific flags
COMPONENT=$(mt_get_flag_value "--component" || echo "all")
APPLY_NOW=false; mt_has_flag "--apply-now" && APPLY_NOW=true
REBUILD_VAULTS=false; mt_has_flag "--rebuild-vaults" && REBUILD_VAULTS=true
KEY_EXPIRATION=$(mt_get_flag_value "--expiration" || echo "8760h")

# Validate component
case "$COMPONENT" in
  pgbouncer|metrics|all) ;;
  *) print_error "Invalid component: $COMPONENT (must be pgbouncer, metrics, or all)"; exit 1 ;;
esac

# Validate expiration format (prevent command injection via SSH)
if ! [[ "$KEY_EXPIRATION" =~ ^[0-9]+[hHdDmM]$ ]]; then
  print_error "Invalid expiration format: $KEY_EXPIRATION (expected e.g. 8760h, 365d)"
  exit 1
fi

# Load infra config (sets HEADSCALE_TAILSCALE_IP, HEADSCALE_SERVER_IP, etc.)
source "${REPO_ROOT}/scripts/lib/infra-config.sh"
mt_load_infra_config

# Resolve Headscale SSH target (prefer Tailscale mesh IP)
HEADSCALE_SSH_HOST=""
if [ -n "${HEADSCALE_TAILSCALE_IP:-}" ] && [ "${HEADSCALE_TAILSCALE_IP}" != "null" ]; then
  HEADSCALE_SSH_HOST="$HEADSCALE_TAILSCALE_IP"
elif [ -n "${HEADSCALE_SERVER_IP:-}" ] && [ "${HEADSCALE_SERVER_IP}" != "null" ] && [ -n "${HEADSCALE_SERVER_IP}" ]; then
  HEADSCALE_SSH_HOST="$HEADSCALE_SERVER_IP"
fi
: "${HEADSCALE_SSH_HOST:?Cannot determine Headscale SSH target. Set headscale.tailscale_ip in infra config.}"

# Resolve infra tenant secrets file
SECRETS_FILE="${INFRA_TENANT_DIR%/}/${MT_ENV}.secrets.yaml"
if [ ! -f "$SECRETS_FILE" ]; then
  print_error "Secrets file not found: $SECRETS_FILE"
  exit 1
fi

# Component definitions: tag, secrets YAML key, K8s secret, namespace, deployment
_component_tag() {
  case "$1" in
    pgbouncer) echo "tag:pgbouncer" ;;
    metrics)   echo "tag:monitoring" ;;
  esac
}

_component_secrets_key() {
  case "$1" in
    pgbouncer) echo "pgbouncer_authkey" ;;
    metrics)   echo "metrics_authkey" ;;
  esac
}

_component_k8s_secret() {
  case "$1" in
    pgbouncer) echo "pgbouncer-tailscale-auth" ;;
    metrics)   echo "pg-metrics-bridge-tailscale-auth" ;;
  esac
}

_component_k8s_namespace() {
  case "$1" in
    pgbouncer) echo "infra-db" ;;
    metrics)   echo "infra-db" ;;
  esac
}

_component_k8s_deployment() {
  case "$1" in
    pgbouncer) echo "deployment/pgbouncer" ;;
    metrics)   echo "deployment/pg-metrics-bridge" ;;
  esac
}

# Build component list
if [ "$COMPONENT" = "all" ]; then
  COMPONENTS=(pgbouncer metrics)
else
  COMPONENTS=("$COMPONENT")
fi

# Validate connectivity
print_status "Connecting to Headscale at $HEADSCALE_SSH_HOST..."
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${HEADSCALE_SSH_HOST}" "headscale version" >/dev/null 2>&1; then
  print_error "Cannot connect to Headscale server at $HEADSCALE_SSH_HOST"
  print_error "Ensure you are on the Tailscale mesh and SSH access is configured"
  exit 1
fi
print_status "Headscale connectivity OK"

# Resolve Headscale user ID for 'infra' (v0.28+ requires numeric ID)
HEADSCALE_USER_ID=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${HEADSCALE_SSH_HOST}" \
  "headscale users list -o json" 2>/dev/null \
  | python3 -c "
import json, sys
for u in json.loads(sys.stdin.read()):
    if u.get('name') == 'infra':
        print(u['id'])
        break
" 2>/dev/null) || true
: "${HEADSCALE_USER_ID:?Could not resolve Headscale user ID for 'infra'}"
if ! [[ "$HEADSCALE_USER_ID" =~ ^[0-9]+$ ]]; then
  print_error "Invalid Headscale user ID: $HEADSCALE_USER_ID (expected numeric)"
  exit 1
fi

# Rotate keys
for comp in "${COMPONENTS[@]}"; do
  tag=$(_component_tag "$comp")
  secrets_key=$(_component_secrets_key "$comp")

  print_status "[$comp] Creating new pre-auth key (tag: $tag, expiration: $KEY_EXPIRATION)..."
  NEW_KEY=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${HEADSCALE_SSH_HOST}" \
    "headscale preauthkeys create --user $HEADSCALE_USER_ID --reusable --expiration $KEY_EXPIRATION --tags $tag" 2>/dev/null)

  if [ -z "$NEW_KEY" ]; then
    print_error "[$comp] Failed to create pre-auth key on Headscale"
    exit 1
  fi
  print_status "[$comp] New key created (length: ${#NEW_KEY})"

  # Update secrets YAML (use strenv to avoid shell injection via key value)
  print_status "[$comp] Updating secrets file..."
  NEW_KEY="$NEW_KEY" yq -i ".tailscale.${secrets_key} = strenv(NEW_KEY)" "$SECRETS_FILE"
  print_success "[$comp] Secrets file updated: $SECRETS_FILE"

  # Apply to K8s if requested
  if [ "$APPLY_NOW" = true ]; then
    k8s_secret=$(_component_k8s_secret "$comp")
    k8s_ns=$(_component_k8s_namespace "$comp")
    k8s_deploy=$(_component_k8s_deployment "$comp")

    print_status "[$comp] Patching K8s secret $k8s_secret in $k8s_ns..."
    kubectl create secret generic "$k8s_secret" -n "$k8s_ns" \
      --from-literal=TS_AUTHKEY="$NEW_KEY" \
      --dry-run=client -o yaml | kubectl apply -f -

    print_status "[$comp] Restarting $k8s_deploy in $k8s_ns..."
    kubectl rollout restart "$k8s_deploy" -n "$k8s_ns"
    kubectl rollout status "$k8s_deploy" -n "$k8s_ns" --timeout=120s
    print_success "[$comp] Pods restarted with new key"
  fi
done

# Rebuild vaults if requested
if [ "$REBUILD_VAULTS" = true ]; then
  print_status "Rebuilding deploy vaults..."
  "$REPO_ROOT/scripts/build-deploy-vaults.sh"
  print_success "Deploy vaults rebuilt"
  echo ""
  echo "Next steps:"
  echo "  1. Commit the updated vault files in config/platform/ci/"
  echo "  2. Re-provision CI: ./ci/scripts/provision-ci.sh --ansible-only"
fi

print_success "Key rotation complete for $MT_ENV (components: ${COMPONENTS[*]})"
