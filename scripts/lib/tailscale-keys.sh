#!/bin/bash
# Tailscale pre-auth key expiry checking and auto-rotation
#
# Provides mt_check_and_rotate_expiring_keys() for use by deploy_infra.
# Queries the Headscale server for pre-auth key expiration timestamps
# and auto-rotates keys that are within the threshold.
#
# Requires: HEADSCALE_TAILSCALE_IP or HEADSCALE_SERVER_IP (from infra-config.sh)
# Requires: INFRA_TENANT_DIR, MT_ENV (from infra-config.sh)

# Guard against double-sourcing
if [ "${_MT_TAILSCALE_KEYS_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_MT_TAILSCALE_KEYS_LOADED=1

# ---------------------------------------------------------------------------
# _mt_resolve_headscale_host — determine SSH target for Headscale
# Returns empty string if no host can be resolved (caller decides what to do)
# ---------------------------------------------------------------------------
_mt_resolve_headscale_host() {
  if [ -n "${HEADSCALE_TAILSCALE_IP:-}" ] && [ "${HEADSCALE_TAILSCALE_IP}" != "null" ]; then
    echo "$HEADSCALE_TAILSCALE_IP"
  elif [ -n "${HEADSCALE_SERVER_IP:-}" ] && [ "${HEADSCALE_SERVER_IP}" != "null" ] && [ -n "${HEADSCALE_SERVER_IP}" ]; then
    echo "$HEADSCALE_SERVER_IP"
  fi
}

# ---------------------------------------------------------------------------
# mt_check_and_rotate_expiring_keys — check key expiry, auto-rotate if needed
#
# Usage: mt_check_and_rotate_expiring_keys <threshold_days>
#   threshold_days: rotate keys expiring within this many days (default: 45)
#
# Requires infra-config.sh to be loaded (HEADSCALE_*, INFRA_TENANT_DIR, MT_ENV).
# ---------------------------------------------------------------------------
mt_check_and_rotate_expiring_keys() {
  local threshold_days="${1:-45}"

  local hs_host
  hs_host=$(_mt_resolve_headscale_host)
  if [ -z "$hs_host" ]; then
    print_warning "Cannot determine Headscale host — skipping key expiry check"
    return 0
  fi

  # Test connectivity (non-fatal — don't block deploys if Headscale is unreachable)
  if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${hs_host}" "true" 2>/dev/null; then
    print_warning "Cannot reach Headscale at $hs_host — skipping key expiry check"
    return 0
  fi

  print_status "Checking Tailscale pre-auth key expiration (threshold: ${threshold_days} days)..."

  # Get pre-auth keys as JSON
  local keys_json
  keys_json=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${hs_host}" \
    "headscale preauthkeys list -o json" 2>/dev/null) || {
    print_warning "Failed to list Headscale pre-auth keys — skipping expiry check"
    return 0
  }

  # Parse expiration and find keys expiring within threshold
  # Headscale v0.28 JSON format: .expiration.seconds (epoch), .acl_tags[], .reusable, .key
  local now_epoch threshold_epoch
  now_epoch=$(date +%s)
  threshold_epoch=$((now_epoch + threshold_days * 86400))

  local expiring_components
  expiring_components=$(echo "$keys_json" | python3 -c "
import json, sys

data = json.loads(sys.stdin.read())
threshold = int(sys.argv[1])
components = set()

# Map ACL tags to component names
tag_to_component = {
    'tag:pgbouncer': 'pgbouncer',
    'tag:postfix-k8s': 'postfix',
}

for key in data:
    # Only check reusable keys (one-time keys are expected to expire)
    if not key.get('reusable', False):
        continue
    tags = key.get('acl_tags', [])
    if not tags:
        continue
    exp = key.get('expiration', {})
    exp_epoch = exp.get('seconds', 0) if isinstance(exp, dict) else 0
    if exp_epoch == 0:
        continue
    if exp_epoch < threshold:
        for tag in tags:
            comp = tag_to_component.get(tag)
            if comp:
                days_left = max(0, (exp_epoch - int(sys.argv[2])) // 86400)
                print(f'{comp}:{days_left}')
                components.add(comp)
" "$threshold_epoch" "$now_epoch" 2>/dev/null) || true

  if [ -z "$expiring_components" ]; then
    print_status "All Tailscale pre-auth keys are valid for at least ${threshold_days} days"
    return 0
  fi

  # Report expiring keys
  print_warning "Tailscale keys expiring within ${threshold_days} days:"
  while IFS=: read -r comp days_left; do
    print_warning "  $comp: expires in ${days_left} days"
  done <<< "$expiring_components"

  # Auto-rotate
  print_status "Auto-rotating expiring keys..."
  local components_to_rotate
  components_to_rotate=$(echo "$expiring_components" | cut -d: -f1 | sort -u | tr '\n' ',' | sed 's/,$//')

  # Rotate each expiring component
  while IFS=: read -r comp _; do
    "$REPO_ROOT/scripts/rotate-tailscale-keys.sh" -e "$MT_ENV" "--component=$comp" --apply-now
  done <<< "$(echo "$expiring_components" | sort -u -t: -k1,1)"

  print_success "Expiring keys rotated"
}
