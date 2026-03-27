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

# Discover K8s service CIDR from CoreDNS ClusterIP (first IP in the range)
COREDNS_IP=$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}')
# Derive /16 CIDR from CoreDNS IP (e.g., 10.128.0.10 → 10.128.0.0/16)
SERVICE_CIDR=$(echo "$COREDNS_IP" | awk -F. '{print $1"."$2".0.0/16"}')
export SERVICE_CIDR

print_status "  Service CIDR: $SERVICE_CIDR"

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

if [[ -n "${HEADSCALE_SERVER_IP:-}" ]]; then
  print_status "Checking Headscale route approval..."
  # Find the router node and enable its routes
  ROUTER_NODE_ID=$(ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
    "root@${HEADSCALE_SERVER_IP}" \
    "headscale nodes list --output json" 2>/dev/null \
    | python3 -c "
import json, sys
for n in json.load(sys.stdin):
    name = n.get('given_name') or n.get('name', '')
    if name.startswith('router-'):
        print(n['id'])
        break
" 2>/dev/null || true)

  if [[ -n "$ROUTER_NODE_ID" ]]; then
    # List and enable unapproved routes
    ROUTES=$(ssh -n -o ConnectTimeout=10 "root@${HEADSCALE_SERVER_IP}" \
      "headscale routes list --output json" 2>/dev/null || true)

    if [[ -n "$ROUTES" ]]; then
      echo "$ROUTES" | python3 -c "
import json, sys
routes = json.load(sys.stdin)
for r in routes:
    if r.get('node', {}).get('id') == ${ROUTER_NODE_ID} and not r.get('enabled', False):
        print(r['id'])
" 2>/dev/null | while IFS= read -r route_id; do
        ssh -n -o ConnectTimeout=10 "root@${HEADSCALE_SERVER_IP}" \
          "headscale routes enable -r $route_id" > /dev/null 2>&1 && \
          print_status "  Enabled route $route_id" || true
      done
    fi
  fi
fi

print_success "Tailscale router deployed to $NS_INGRESS_INTERNAL"
echo ""
echo "Next steps:"
echo "  1. Configure Headscale split DNS for internal domains"
echo "  2. Test: dig @<router-tailscale-ip> grafana.${MT_ENV}.mother-tree.org"
