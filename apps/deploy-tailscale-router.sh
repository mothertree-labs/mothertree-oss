#!/usr/bin/env bash
set -euo pipefail

# Deploy Tailscale Subnet Router + Unbound DNS
#
# Provides operator access to internal K8s services (Grafana, Prometheus, etc.)
# over the Tailscale mesh. Two components:
#
#   1. Tailscale subnet router: advertises the K8s service CIDR so operator
#      laptops can reach ClusterIPs through the mesh.
#   2. Unbound DNS: resolves internal hostnames (e.g., grafana.prod.mother-tree.org)
#      to the internal ingress controller's ClusterIP. Headscale split DNS routes
#      these queries to Unbound.
#
# Usage:
#   ./apps/deploy-tailscale-router.sh -e <env>

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  echo "Usage: $0 -e <env>"
  echo ""
  echo "Deploy Tailscale subnet router + Unbound DNS for operator access."
  echo ""
  echo "Options:"
  echo "  -e <env>       Environment (e.g., dev, prod)"
  echo "  -h, --help     Show this help"
}

mt_parse_args "$@"
mt_require_env

source "${REPO_ROOT}/scripts/lib/infra-config.sh"
mt_load_infra_config

mt_require_commands kubectl envsubst shasum

MANIFESTS_DIR="$REPO_ROOT/apps/manifests/tailscale-router"

: "${HEADSCALE_URL:?HEADSCALE_URL not set}"
: "${TAILSCALE_AUTHKEY:?TAILSCALE_AUTHKEY not set}"

print_status "Deploying Tailscale router to $NS_INGRESS_INTERNAL (env: $MT_ENV)"

# =============================================================================
# Discover internal ingress ClusterIP and hostnames
# =============================================================================

INTERNAL_INGRESS_IP=$(kubectl get svc -n "$NS_INGRESS_INTERNAL" \
  ingress-nginx-internal-controller -o jsonpath='{.spec.clusterIP}')
: "${INTERNAL_INGRESS_IP:?Could not determine internal ingress ClusterIP}"

print_status "  Internal ingress ClusterIP: $INTERNAL_INGRESS_IP"

# Advertise only the internal ingress ClusterIP as a /32 route.
# Using the full service CIDR (/16) would conflict when multiple clusters
# share the same CIDR (e.g., prod and prod-eu both use 10.128.0.0/16).
# A /32 for each cluster's ingress ClusterIP is unique and non-overlapping.
SERVICE_CIDR="${INTERNAL_INGRESS_IP}/32"
export SERVICE_CIDR

print_status "  Advertised route: $SERVICE_CIDR"

# Discover all hostnames served by the internal ingress
INTERNAL_HOSTS=$(kubectl get ingress -A -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
hosts = set()
for ing in data.get('items', []):
    if ing.get('spec', {}).get('ingressClassName') == 'nginx-internal':
        for rule in ing.get('spec', {}).get('rules', []):
            host = rule.get('host', '')
            if host:
                hosts.add(host)
for h in sorted(hosts):
    print(h)
")

HOST_COUNT=$(echo "$INTERNAL_HOSTS" | wc -l | tr -d ' ')
print_status "  Internal hostnames: $HOST_COUNT"

# Generate Unbound local-data entries
UNBOUND_LOCAL_DATA=""
while IFS= read -r host; do
  [[ -z "$host" ]] && continue
  UNBOUND_LOCAL_DATA="${UNBOUND_LOCAL_DATA}  local-data: \"${host}. 60 IN A ${INTERNAL_INGRESS_IP}\"\n"
  print_status "    $host → $INTERNAL_INGRESS_IP"
done <<< "$INTERNAL_HOSTS"
export UNBOUND_LOCAL_DATA

# =============================================================================
# Generate configs
# =============================================================================

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

# Generate Unbound config
echo -e "$(envsubst '${UNBOUND_LOCAL_DATA}' < "$MANIFESTS_DIR/unbound.conf.tpl")" > "$WORK_DIR/unbound.conf"

CHECKSUM_UNBOUND_CONFIG=$(shasum -a 256 "$WORK_DIR/unbound.conf" | cut -d' ' -f1)
export CHECKSUM_UNBOUND_CONFIG MT_ENV

# =============================================================================
# Apply RBAC
# =============================================================================

print_status "Applying Tailscale router RBAC..."
mt_reset_change_tracker
envsubst '${NS_INGRESS_INTERNAL}' \
  < "$MANIFESTS_DIR/rbac.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply Tailscale auth secret
# =============================================================================

print_status "Applying Tailscale router auth secret..."
kubectl create secret generic tailscale-router-auth -n "$NS_INGRESS_INTERNAL" \
  --from-literal=TS_AUTHKEY="$TAILSCALE_AUTHKEY" \
  --dry-run=client -o yaml | mt_apply kubectl apply -f -

# =============================================================================
# Apply Unbound ConfigMap
# =============================================================================

print_status "Applying Unbound DNS config..."
kubectl create configmap tailscale-router-unbound -n "$NS_INGRESS_INTERNAL" \
  --from-file=unbound.conf="$WORK_DIR/unbound.conf" \
  --dry-run=client -o yaml | mt_apply kubectl apply -f -

# =============================================================================
# Apply Deployment
# =============================================================================

print_status "Applying Tailscale router Deployment..."
envsubst '${NS_INGRESS_INTERNAL} ${HEADSCALE_URL} ${SERVICE_CIDR} ${MT_ENV} ${CHECKSUM_UNBOUND_CONFIG}' \
  < "$MANIFESTS_DIR/deployment.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Conditional restart + rollout wait
# =============================================================================

mt_restart_if_changed deployment/tailscale-router -n "$NS_INGRESS_INTERNAL"

print_status "Waiting for Tailscale router rollout..."
kubectl rollout status deployment/tailscale-router -n "$NS_INGRESS_INTERNAL" --timeout=120s

# =============================================================================
# Approve routes in Headscale (if not auto-approved by ACL policy)
# =============================================================================

# Approve the /32 route in Headscale so the subnet router can forward traffic.
# Prod and prod-eu share a Headscale server (provisioned in prod-eu). If the
# local env doesn't have HEADSCALE_SERVER_IP, try loading it from prod-eu outputs.
HS_IP="${HEADSCALE_SERVER_IP:-}"
if [[ -z "$HS_IP" ]]; then
  # Shared Headscale: check prod-eu terraform outputs
  PRODEU_OUTPUTS="${REPO_ROOT}/config/platform/infra/terraform-outputs.prod-eu.env"
  if [[ -f "$PRODEU_OUTPUTS" ]]; then
    HS_IP=$(grep "^HEADSCALE_SERVER_IP=" "$PRODEU_OUTPUTS" 2>/dev/null | cut -d'"' -f2)
  fi
fi

if [[ -n "$HS_IP" ]]; then
  export ROUTER_NAME="router-${MT_ENV}"

  # Query Headscale node list once and extract both node ID and Tailscale IP
  print_status "Querying Headscale for router node ($HS_IP)..."
  ROUTER_INFO=$(ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
    "root@${HS_IP}" \
    "headscale nodes list --output json" 2>/dev/null \
    | ROUTER_NAME="$ROUTER_NAME" python3 -c "
import json, sys, os
target = os.environ['ROUTER_NAME']
for n in json.load(sys.stdin):
    name = n.get('given_name') or n.get('name', '')
    if name == target:
        ips = n.get('ip_addresses', [])
        print(f'{n[\"id\"]} {ips[0] if ips else \"\"}')
        break
" 2>/dev/null || true)

  ROUTER_NODE_ID="${ROUTER_INFO%% *}"
  ROUTER_TS_IP="${ROUTER_INFO#* }"

  # ── Approve routes ──────────────────────────────────────────────────
  if [[ -n "$ROUTER_NODE_ID" ]]; then
    print_status "Approving route in Headscale..."
    ssh -n -o ConnectTimeout=10 "root@${HS_IP}" \
      "headscale nodes approve-routes -i $ROUTER_NODE_ID -r $SERVICE_CIDR" > /dev/null 2>&1 && \
      print_status "  Route $SERVICE_CIDR approved for node $ROUTER_NODE_ID" || \
      print_warning "  Route approval failed (may need manual approval)"
  else
    print_warning "  Router node '$ROUTER_NAME' not found in Headscale — approve route manually"
  fi

  # ── Configure split DNS in Headscale ──────────────────────────────
  # Route internal domain queries to this router's Unbound DNS.
  if [[ -n "$ROUTER_TS_IP" ]]; then
    # Determine the split DNS domain for this environment
    case "$MT_ENV" in
      dev)     SPLIT_DOMAIN="internal.dev.${INFRA_DOMAIN}" ;;
      prod-eu) SPLIT_DOMAIN="prod-eu.${INFRA_DOMAIN}" ;;
      *)       SPLIT_DOMAIN="${MT_ENV}.${INFRA_DOMAIN}" ;;
    esac

    print_status "Configuring split DNS: ${SPLIT_DOMAIN} → ${ROUTER_TS_IP}"
    ssh -n -o ConnectTimeout=10 "root@${HS_IP}" \
      "DOMAIN='${SPLIT_DOMAIN}' IP='${ROUTER_TS_IP}' python3 -c \"
import yaml, os
domain = os.environ['DOMAIN']
ip = os.environ['IP']
with open('/etc/headscale/config.yaml') as f:
    config = yaml.safe_load(f)
split = config.setdefault('dns', {}).setdefault('nameservers', {}).setdefault('split', {})
split[domain] = [ip]
config['dns']['override_local_dns'] = False
with open('/etc/headscale/config.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
print(f'Split DNS: {domain} -> {ip}')
\" && systemctl restart headscale" 2>&1 | sed 's/^/  /' || \
      print_warning "  Split DNS configuration failed (configure manually)"

    # Persist split DNS config for Ansible so manage_infra --ansible
    # won't overwrite it. Write a state file that manage_infra reads
    # to populate the tailscale_router_dns Ansible variable.
    ROUTER_DNS_DIR="${REPO_ROOT}/config/platform/infra"
    if [[ -d "$ROUTER_DNS_DIR" ]]; then
      ROUTER_DNS_FILE="${ROUTER_DNS_DIR}/tailscale-router-dns.${MT_ENV}.env"
      echo "# Auto-generated by deploy-tailscale-router.sh — do not edit manually" > "$ROUTER_DNS_FILE"
      echo "TAILSCALE_ROUTER_DNS_DOMAIN=\"${SPLIT_DOMAIN}\"" >> "$ROUTER_DNS_FILE"
      echo "TAILSCALE_ROUTER_DNS_IP=\"${ROUTER_TS_IP}\"" >> "$ROUTER_DNS_FILE"
      print_status "  Saved split DNS state to ${ROUTER_DNS_FILE}"
    fi
  fi
else
  print_warning "  Headscale server IP not available — approve route manually"
fi

print_success "Tailscale router deployed to $NS_INGRESS_INTERNAL"
