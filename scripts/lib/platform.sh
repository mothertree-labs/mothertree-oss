#!/bin/bash
# Cluster platform helpers — what kind of Kubernetes an environment runs on.
#
# Set per environment in the infra config (config/platform/infra/<env>.config.yaml):
#
#   cluster:
#     platform: lke        # default — Linode LKE behind a NodeBalancer
#   # or
#   cluster:
#     platform: k3s        # single-node k3s (k3d) behind a public L4 forwarder
#     public_ip: 203.0.113.10   # REQUIRED for k3s: the forwarder's public IPv4
#
# On LKE the ingress Service's LoadBalancer status IS the public address. On
# k3s the Service is served by k3s's ServiceLB and reports a node-local address
# that nothing outside the box can reach, so every consumer of "the public
# ingress IP" (DNS records, HTTP-01 SAN filtering, the inbound-mail A record,
# Jitsi's advertised media address) must use cluster.public_ip instead. Use
# mt_ingress_public_ip for that — never read .status.loadBalancer directly.
#
# Usage:
#   source "${REPO_ROOT}/scripts/lib/platform.sh"
#   mt_load_cluster_platform          # exports MT_CLUSTER_PLATFORM (+ MT_PUBLIC_INGRESS_IP on k3s)
#   if mt_is_k3s; then ...; fi
#   ip=$(mt_ingress_public_ip)        # fails (rc 1) when unknown

if [ "${_MT_PLATFORM_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_MT_PLATFORM_LOADED=1

# mt_load_cluster_platform — read cluster.platform / cluster.public_ip for
# $MT_ENV. Idempotent. Fails fast on an unknown platform or a k3s env without a
# valid public_ip (Fail Fast: a missing value must never silently fall back to
# the node-local LB address).
mt_load_cluster_platform() {
  [ -n "${MT_CLUSTER_PLATFORM:-}" ] && [ "${_MT_PLATFORM_ENV:-}" = "${MT_ENV:-}" ] && return 0
  : "${MT_ENV:?MT_ENV is required to resolve the cluster platform}"
  : "${REPO_ROOT:?REPO_ROOT is required to resolve the cluster platform}"

  local cfg="${MT_INFRA_CONFIG:-}"
  if [ -z "$cfg" ]; then
    # shellcheck source=paths.sh
    source "${REPO_ROOT}/scripts/lib/paths.sh"
    _mt_resolve_infra_config "$MT_ENV"
    cfg="${MT_INFRA_CONFIG:-}"
  fi

  local platform="lke" public_ip=""
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    platform=$(yq '.cluster.platform // "lke"' "$cfg")
    public_ip=$(yq '.cluster.public_ip // ""' "$cfg")
  fi

  case "$platform" in
    lke) ;;
    k3s)
      if ! [[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "[ERROR] cluster.platform is k3s but cluster.public_ip ('${public_ip}') is not an IPv4 address in ${cfg:-<no infra config>}" >&2
        exit 1
      fi
      export MT_PUBLIC_INGRESS_IP="$public_ip"
      ;;
    *)
      echo "[ERROR] Unknown cluster.platform '${platform}' in ${cfg:-<no infra config>} (expected lke or k3s)" >&2
      exit 1
      ;;
  esac
  export MT_CLUSTER_PLATFORM="$platform"
  _MT_PLATFORM_ENV="$MT_ENV"
}

mt_is_k3s() {
  mt_load_cluster_platform
  [ "$MT_CLUSTER_PLATFORM" = "k3s" ]
}

mt_is_lke() {
  mt_load_cluster_platform
  [ "$MT_CLUSTER_PLATFORM" = "lke" ]
}

# mt_ingress_public_ip — print the public IPv4 clients use to reach the
# ingress. k3s: cluster.public_ip. LKE: the ingress Service's LoadBalancer IP
# (needs NS_INGRESS + a working KUBECONFIG). Prints nothing and returns 1 when
# the LKE address is not (yet) assigned; callers decide whether that is fatal.
mt_ingress_public_ip() {
  mt_load_cluster_platform
  if [ "$MT_CLUSTER_PLATFORM" = "k3s" ]; then
    printf '%s\n' "$MT_PUBLIC_INGRESS_IP"
    return 0
  fi
  local ip
  ip=$(kubectl get service -n "${NS_INGRESS:-infra-ingress}" ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ -n "$ip" ] || return 1
  printf '%s\n' "$ip"
}
