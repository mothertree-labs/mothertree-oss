#!/bin/bash

# Deploy Cross-Cluster Metrics Federation bridge
# Purpose: Let grafana.prod query the prod-eu Prometheus over the Headscale mesh,
#          consolidating all metrics into a single Grafana viewer (grafana.prod).
#
# Two roles, selected by `metrics_federation.role` in the infra config:
#
#   role: exposer  (prod-eu)
#       Deploys `prometheus-mesh-expose`: a socat + Tailscale (tag:monitoring)
#       sidecar pod that exposes the in-cluster Prometheus (ClusterIP :9090) on
#       the mesh via the pod's own 100.64.x.x address.
#
#   role: consumer (prod)
#       Deploys `prometheus-eu-bridge`: a socat + Tailscale sidecar pod that
#       forwards an in-cluster ClusterIP (:9090) to the prod-eu exposer's mesh IP
#       (metrics_federation.source_mesh_ip), PLUS a Grafana datasource ConfigMap
#       registering "Prometheus (prod-eu)" (uid: prometheus-eu).
#
#   (role unset)   -> feature disabled for this env; the script is a no-op.
#
# Bootstrap order (operator):
#   1. Set metrics_federation.role: exposer in the prod-eu infra config; ensure a
#      reusable tag:monitoring pre-auth key exists (tailscale.metrics_authkey).
#   2. deploy_infra -e prod-eu  (deploys the exposer); read its assigned mesh IP:
#        tailscale --socket=... status   (or: headscale nodes list | grep prom-mesh)
#   3. Add an ACL rule allowing tag:monitoring -> tag:monitoring:9090 and redeploy
#      the Headscale ACL (ansible/templates/headscale-acl-policy.json.j2).
#   4. Set metrics_federation.role: consumer AND metrics_federation.source_mesh_ip:
#      <exposer mesh IP> in the prod infra config.
#   5. deploy_infra -e prod  (deploys the consumer + datasource).
#
# Required infra config (config/platform/infra/<env>.config.yaml):
#   metrics_federation:
#     role: exposer | consumer
#     source_mesh_ip: "100.64.x.x"   # consumer only
# Required infra secret (config/platform/infra/<env>.secrets.yaml):
#   tailscale:
#     metrics_authkey: "<reusable tag:monitoring pre-auth key>"
#
# Called by: deploy_infra (after pg-metrics-bridge). Can also be run standalone.
#
# Usage:
#   ./apps/deploy-metrics-federation.sh -e <env>

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  echo "Usage: $0 -e <env>"
  echo ""
  echo "Deploy the cross-cluster metrics federation bridge (socat + Tailscale) so"
  echo "grafana.prod can query the prod-eu Prometheus over the Headscale mesh."
  echo ""
  echo "Role is selected by metrics_federation.role in the infra config"
  echo "(exposer on prod-eu, consumer on prod). Unset = no-op."
  echo ""
  echo "Options:"
  echo "  -e <env>       Environment (e.g., prod, prod-eu)"
  echo "  -h, --help     Show this help"
}

mt_parse_args "$@"
mt_require_env

# Load infrastructure configuration
source "${REPO_ROOT}/scripts/lib/infra-config.sh"
mt_load_infra_config

mt_require_commands kubectl envsubst

MANIFESTS_DIR="$REPO_ROOT/apps/manifests/metrics-federation"

# =============================================================================
# Feature gate — disabled unless a role is configured
# =============================================================================

ROLE="${MT_METRICS_FED_ROLE:-}"
if [ -z "$ROLE" ] || [ "$ROLE" = "null" ]; then
  print_status "Metrics federation not enabled for $MT_ENV (set metrics_federation.role in infra config). Skipping."
  exit 0
fi

: "${HEADSCALE_URL:?HEADSCALE_URL not set. Add headscale.url to infra config.}"
export HEADSCALE_URL
export NS_MONITORING

# Tailscale pre-auth key — only needed for first-time bootstrap.
# After initial creation, the key-rotator CronJob manages this secret.
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY_METRICS:-${TAILSCALE_AUTHKEY:-}}"

# =============================================================================
# Role selection
# =============================================================================

DEPLOY_DATASOURCE=false
case "$ROLE" in
  exposer)
    # prod-eu: expose the in-cluster Prometheus on the mesh.
    export FED_NAME="prometheus-mesh-expose"
    export SOCAT_TARGET="kube-prometheus-stack-prometheus.${NS_MONITORING}.svc.cluster.local:9090"
    export TS_HOSTNAME="prom-mesh-${MT_ENV}"
    ;;
  consumer)
    # prod: forward an in-cluster ClusterIP to the prod-eu exposer's mesh IP.
    : "${MT_METRICS_FED_SOURCE_IP:?metrics_federation.source_mesh_ip is required when role=consumer (the prod-eu exposer's 100.64.x.x mesh IP — see bootstrap steps in this script's header).}"
    # Defence-in-depth: this value flows straight into socat args, so reject anything
    # that is not a Tailscale CGNAT mesh IP (100.64.0.0/10 → second octet 64-127).
    if ! [[ "$MT_METRICS_FED_SOURCE_IP" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      print_error "metrics_federation.source_mesh_ip ('$MT_METRICS_FED_SOURCE_IP') is not a Tailscale mesh IP (expected 100.64.0.0/10, e.g. 100.64.0.x)"
      exit 1
    fi
    export FED_NAME="prometheus-eu-bridge"
    export SOCAT_TARGET="${MT_METRICS_FED_SOURCE_IP}:9090"
    export TS_HOSTNAME="prom-eu-bridge-${MT_ENV}"
    DEPLOY_DATASOURCE=true
    ;;
  *)
    print_error "Unknown metrics_federation.role '$ROLE' (expected: exposer | consumer)"
    exit 1
    ;;
esac

print_status "Deploying metrics federation ($ROLE) to $NS_MONITORING (env: $MT_ENV)"
print_status "  Pod/Service:  $FED_NAME"
print_status "  socat target: $SOCAT_TARGET"
print_status "  Headscale URL: $HEADSCALE_URL"

mt_reset_change_tracker

# =============================================================================
# Apply RBAC
# =============================================================================

print_status "Applying metrics federation RBAC..."
envsubst '${NS_MONITORING} ${FED_NAME}' < "$MANIFESTS_DIR/rbac.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply Secret (create only if missing — managed by key-rotator CronJob)
# =============================================================================

if ! kubectl get secret "${FED_NAME}-tailscale-auth" -n "$NS_MONITORING" >/dev/null 2>&1; then
  if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
    print_error "${FED_NAME}-tailscale-auth secret does not exist and no Tailscale auth key is set"
    print_error "Bootstrap: create a reusable tag:monitoring pre-auth key and set tailscale.metrics_authkey in infra secrets"
    exit 1
  fi
  print_status "Creating metrics federation Tailscale auth secret (first-time bootstrap)..."
  envsubst '${NS_MONITORING} ${FED_NAME} ${TAILSCALE_AUTHKEY}' \
    < "$MANIFESTS_DIR/secret.yaml.tpl" | mt_apply kubectl apply -f -
else
  print_status "Tailscale auth secret exists (managed by key-rotator CronJob)"
fi

# =============================================================================
# Apply Deployment + Service
# =============================================================================

print_status "Applying metrics federation Deployment..."
envsubst '${NS_MONITORING} ${FED_NAME} ${SOCAT_TARGET} ${HEADSCALE_URL} ${TS_HOSTNAME}' \
  < "$MANIFESTS_DIR/deployment.yaml.tpl" | mt_apply kubectl apply -f -

print_status "Applying metrics federation Service..."
envsubst '${NS_MONITORING} ${FED_NAME}' < "$MANIFESTS_DIR/service.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply Grafana datasource (consumer only)
# =============================================================================

if [ "$DEPLOY_DATASOURCE" = true ]; then
  print_status "Registering 'Prometheus (prod-eu)' Grafana datasource..."
  envsubst '${NS_MONITORING}' < "$MANIFESTS_DIR/grafana-datasource.configmap.yaml.tpl" | mt_apply kubectl apply -f -
fi

# =============================================================================
# Conditional restart + rollout wait
# =============================================================================

mt_restart_if_changed "deployment/${FED_NAME}" -n "$NS_MONITORING"

if mt_has_changes; then
  print_status "Waiting for metrics federation rollout..."
  kubectl rollout status "deployment/${FED_NAME}" -n "$NS_MONITORING" --timeout=120s
fi

print_success "Metrics federation ($ROLE) deployed to $NS_MONITORING"
