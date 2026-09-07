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
#       forwards an in-cluster ClusterIP (:9090) to the exposer's mesh IP, PLUS a
#       Grafana datasource ConfigMap registering "Prometheus (prod-eu)"
#       (uid: prometheus-eu). The exposer's mesh IP is DISCOVERED from Headscale
#       at deploy time (the online node advertising hostname prom-mesh-<env>
#       with tag:monitoring); metrics_federation.source_mesh_ip is only a
#       fallback for when no exposer is online.
#
#   (role unset)   -> feature disabled for this env; the script is a no-op.
#
# Node identity: both pods keep a FIXED-name Tailscale state Secret
# (<name>-tailscale-state), so a pod recreation re-registers the same Headscale
# node and keeps its mesh IP. Until 2026-09 the state Secret was per pod name,
# and every recreation of the exposer registered a new node with a new IP that
# the consumer's static config never learned about (audit cause 7). A cluster
# still on a per-pod Secret is migrated on the first deploy: the running pod's
# state is adopted under the fixed name so the node (and IP) is preserved.
#
# Bootstrap order (operator):
#   1. Set metrics_federation.role: exposer in the prod-eu infra config. The
#      sidecar's tag:monitoring pre-auth key is minted via the Headscale API
#      (tailscale.rotator_api_key) — nothing to pre-create.
#   2. deploy_infra -e prod-eu  (deploys the exposer; the script prints the
#      node's mesh IP at the end — nothing to copy anywhere).
#   3. Add an ACL rule allowing tag:monitoring -> tag:monitoring:9090 and redeploy
#      the Headscale ACL (ansible/templates/headscale-acl-policy.json.j2).
#   4. Set metrics_federation.role: consumer (and, recommended,
#      metrics_federation.source_env: prod-eu) in the prod infra config.
#   5. deploy_infra -e prod  (deploys the consumer + datasource).
#
# Required infra config (config/platform/infra/<env>.config.yaml):
#   metrics_federation:
#     role: exposer | consumer
#     source_env: "prod-eu"          # consumer, optional: the exposer's environment
#     source_mesh_ip: "100.64.x.x"   # consumer, optional: fallback when no exposer is online
# Required infra secret (infra tenant <env>.secrets.yaml):
#   tailscale:
#     rotator_api_key: "<Headscale API key>"   # mints/verifies the sidecar's key, lists nodes
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

mt_require_commands kubectl envsubst jq

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

# Tailscale pre-auth keys are minted through the Headscale API (tag:monitoring, 90 days)
# on first-time bootstrap and whenever the key in the Secret turns out to be
# missing, untagged, single-use, expired or near expiry (#613). The in-cluster
# key-rotator CronJob runs the same check daily. The same API lists the mesh
# nodes, which is how the consumer finds the exposer. See scripts/lib/tailscale-keys.sh.
: "${TAILSCALE_ROTATOR_API_KEY:?tailscale.rotator_api_key not set in infra secrets — required to mint/verify the metrics federation sidecar pre-auth key and to discover the exposer (headscale apikeys create --expiration 87600h)}"
HEADSCALE_API_KEY="$TAILSCALE_ROTATOR_API_KEY"
source "${REPO_ROOT}/scripts/lib/tailscale-keys.sh"

# =============================================================================
# Consumer: resolve the exposer's CURRENT mesh IP
# =============================================================================

# Sets EXPOSER_IP. Discovery (an online tag:monitoring node advertising
# prom-mesh-<source_env>, or any prom-mesh-* node when source_env is unset)
# wins over metrics_federation.source_mesh_ip, which only covers the case
# where no exposer is online right now. Ambiguity (two online exposers) and
# "nothing online, no fallback" are fatal: guessing an address would only move
# the failure to the positive control below.
_fed_resolve_exposer_ip() {
  local re found fallback="${MT_METRICS_FED_SOURCE_IP:-}"
  EXPOSER_IP=""
  if [ -n "${MT_METRICS_FED_SOURCE_ENV:-}" ]; then
    re="^prom-mesh-${MT_METRICS_FED_SOURCE_ENV}\$"
  else
    re="^prom-mesh-"
  fi
  print_status "Discovering the exposer on Headscale (online tag:monitoring node matching /$re/)..."
  if found=$(mt_ts_resolve_node "$re" tag:monitoring 90); then
    EXPOSER_IP=$(printf '%s' "$found" | cut -f2)
    print_status "Exposer found: node $(printf '%s' "$found" | cut -f1) at $EXPOSER_IP"
    if [ -n "$fallback" ] && [ "$fallback" != "$EXPOSER_IP" ]; then
      print_warning "metrics_federation.source_mesh_ip ($fallback) is stale — the exposer is at $EXPOSER_IP; the discovered address is used. Update or drop the config value."
    fi
    return 0
  fi
  case "$MT_TS_RESOLVE_REASON" in
    api)
      printf '%s\n' "$found"
      print_error "Cannot list Headscale nodes to find the exposer — see the error above"
      return 1 ;;
    ambiguous)
      print_error "More than one online exposer matches /$re/ — set metrics_federation.source_env in the infra config to pick one:"
      printf '%s\n' "$MT_TS_RESOLVE_CANDIDATES" | sed 's/^/    /'
      return 1 ;;
  esac
  if [ -n "$fallback" ]; then
    print_warning "No online exposer matches /$re/ on Headscale — falling back to metrics_federation.source_mesh_ip ($fallback); the positive control below decides."
    EXPOSER_IP="$fallback"
    return 0
  fi
  print_error "No online exposer matches /$re/ on Headscale and metrics_federation.source_mesh_ip is unset — is the exposer deployed and on the mesh?"
  return 1
}

# =============================================================================
# Role selection
# =============================================================================

DEPLOY_DATASOURCE=false
EXPOSER_IP=""
case "$ROLE" in
  exposer)
    # prod-eu: expose the in-cluster Prometheus on the mesh.
    export FED_NAME="prometheus-mesh-expose"
    export SOCAT_TARGET="kube-prometheus-stack-prometheus.${NS_MONITORING}.svc.cluster.local:9090"
    export TS_HOSTNAME="prom-mesh-${MT_ENV}"
    ;;
  consumer)
    # prod: forward an in-cluster ClusterIP to the exposer's mesh IP.
    if [ -n "${MT_METRICS_FED_SOURCE_IP:-}" ]; then
      mt_require_mesh_ip MT_METRICS_FED_SOURCE_IP "$MT_METRICS_FED_SOURCE_IP" "metrics_federation.source_mesh_ip"
    fi
    _fed_resolve_exposer_ip || exit 1
    # Defence-in-depth: this value flows straight into socat args and the mesh
    # probe's argv, so it must be a Tailscale CGNAT mesh IP (100.64.0.0/10).
    mt_require_mesh_ip EXPOSER_IP "$EXPOSER_IP" "discovered exposer mesh IP"
    export FED_NAME="prometheus-eu-bridge"
    export SOCAT_TARGET="${EXPOSER_IP}:9090"
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
# Apply Secret (verified against Headscale; minted when missing or unusable)
# =============================================================================

print_status "Verifying metrics federation Tailscale auth key..."
mt_ts_ensure_secret "$NS_MONITORING" "${FED_NAME}-tailscale-auth" tag:monitoring "$FED_NAME"

# =============================================================================
# Node identity — fixed-name state Secret (one-time adoption from per-pod state)
# =============================================================================

# A cluster still running the per-pod layout has its live node identity copied
# under the fixed name BEFORE the Deployment rolls, so the new pod comes up as
# the same Headscale node with the same mesh IP (the consumer on the other
# cluster keeps working). Flags the change tracker when it wrote the Secret.
print_status "Ensuring the fixed-name Tailscale state Secret (stable node identity)..."
mt_ts_adopt_pod_state_secret "$NS_MONITORING" "$FED_NAME" "app=${FED_NAME}"

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

# =============================================================================
# Mesh gate — unconditional (a Ready pod says nothing about the tunnel, #613)
# =============================================================================

# The mesh gate is fatal on purpose: a federation sidecar with a dead or
# untagged key is exactly the #613 failure class, and prod-eu has no alert
# delivery yet, so a blocked deploy is the only signal that would be seen.
mt_wait_for_tailscale_sidecar "$NS_MONITORING" "app=${FED_NAME}" tag:monitoring
if [ "$ROLE" = consumer ]; then
  # Positive control on the real target: the exposer's Prometheus answers
  # through the tunnel. Fatal: the address was just discovered from Headscale
  # (or is the configured fallback), so a miss here is a dead federation path —
  # the Grafana "Prometheus (prod-eu)" datasource would be down — and the
  # MetricsFederationDown alert only fires once Prometheus notices.
  mt_tailscale_sidecar_fetch "$NS_MONITORING" "app=${FED_NAME}" "http://${EXPOSER_IP}:9090/-/ready" 'Ready' 60 \
    || { print_error "Federation consumer cannot reach the exposer's Prometheus at ${EXPOSER_IP}:9090 over the mesh (exposer down, ACL tag:monitoring -> tag:monitoring:9090 missing, or a stale metrics_federation.source_mesh_ip fallback)"; exit 1; }
else
  # Exposer: report what the other cluster will discover.
  if found=$(mt_ts_find_online_nodes "^${TS_HOSTNAME}\$" tag:monitoring); then
    if [ -n "$found" ]; then
      print_status "Exposer online on Headscale (node, mesh IP) — the consumer discovers this at its next deploy:"
      printf '%s\n' "$found" | sed 's/^/    /'
    else
      print_warning "Headscale lists no online node named ${TS_HOSTNAME} yet (the sidecar just joined — the map poll may lag a few seconds)"
    fi
  else
    printf '%s\n' "$found"
    print_warning "Could not read the exposer's node back from Headscale (read-back only; the mesh gate above already passed)"
  fi
fi

# =============================================================================
# Housekeeping — per-pod state Secrets left by the previous layout / pod churn
# =============================================================================

mt_ts_prune_pod_state_secrets "$NS_MONITORING" "$FED_NAME"

print_success "Metrics federation ($ROLE) deployed to $NS_MONITORING"
