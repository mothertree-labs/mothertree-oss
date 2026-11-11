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
#   # or
#   cluster:
#     platform: k3s
#     edge: local          # a developer box (devbox): nothing on the internet
#                          # points at this cluster. public_ip must be absent;
#                          # the ingress is published on 127.0.0.1.
#
# cluster.edge is `public` (default — LKE NodeBalancer, or a k3s box behind a
# public forwarder) or `local`. `local` is only valid on k3s. Deploy scripts
# gate the things a local box cannot have (Cloudflare DNS, Let's Encrypt, the
# Headscale mesh) on mt_is_local_edge and log why they skip; on a public edge a
# missing token for those stays fatal.
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
#   mt_load_cluster_platform          # exports MT_CLUSTER_PLATFORM, MT_CLUSTER_EDGE
#                                     # (+ MT_PUBLIC_INGRESS_IP on k3s)
#   if mt_is_k3s; then ...; fi
#   if mt_is_local_edge; then ...; fi
#   ip=$(mt_ingress_public_ip)        # fails (rc 1) when unknown

if [ "${_MT_PLATFORM_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_MT_PLATFORM_LOADED=1

# mt_load_cluster_platform — read cluster.platform / cluster.edge /
# cluster.public_ip for $MT_ENV. Idempotent. Fails fast on an unknown platform
# or edge, edge: local on LKE, or a public-edge k3s env without a valid public_ip (Fail Fast: a missing value must never silently fall back to
# the node-local LB address).
mt_load_cluster_platform() {
  [ -n "${MT_CLUSTER_PLATFORM:-}" ] && [ -n "${MT_CLUSTER_EDGE:-}" ] \
    && [ "${_MT_PLATFORM_ENV:-}" = "${MT_ENV:-}" ] && return 0
  : "${MT_ENV:?MT_ENV is required to resolve the cluster platform}"
  : "${REPO_ROOT:?REPO_ROOT is required to resolve the cluster platform}"

  local cfg="${MT_INFRA_CONFIG:-}"
  if [ -z "$cfg" ]; then
    # shellcheck source=paths.sh
    source "${REPO_ROOT}/scripts/lib/paths.sh"
    _mt_resolve_infra_config "$MT_ENV"
    cfg="${MT_INFRA_CONFIG:-}"
  fi

  local platform="lke" public_ip="" edge="public"
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    platform=$(yq '.cluster.platform // "lke"' "$cfg")
    public_ip=$(yq '.cluster.public_ip // ""' "$cfg")
    edge=$(yq '.cluster.edge // "public"' "$cfg")
  fi

  case "$edge" in
    public|local) ;;
    *)
      echo "[ERROR] Unknown cluster.edge '${edge}' in ${cfg:-<no infra config>} (expected public or local)" >&2
      exit 1
      ;;
  esac

  case "$platform" in
    lke)
      if [ "$edge" = "local" ]; then
        echo "[ERROR] cluster.edge: local is only valid on cluster.platform: k3s (${cfg}); an LKE cluster always has a public edge" >&2
        exit 1
      fi
      ;;
    k3s)
      if [ "$edge" = "local" ]; then
        # A local box has no public address. A public_ip here means the config
        # is confused about which kind of box this is — refuse rather than guess.
        if [ -n "$public_ip" ]; then
          echo "[ERROR] cluster.edge is local but cluster.public_ip ('${public_ip}') is set in ${cfg}; a local-edge box has no public address — remove one of them" >&2
          exit 1
        fi
        export MT_PUBLIC_INGRESS_IP="127.0.0.1"
      elif ! [[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "[ERROR] cluster.platform is k3s but cluster.public_ip ('${public_ip}') is not an IPv4 address in ${cfg:-<no infra config>}" >&2
        exit 1
      else
        export MT_PUBLIC_INGRESS_IP="$public_ip"
      fi
      ;;
    *)
      echo "[ERROR] Unknown cluster.platform '${platform}' in ${cfg:-<no infra config>} (expected lke or k3s)" >&2
      exit 1
      ;;
  esac
  export MT_CLUSTER_PLATFORM="$platform"
  export MT_CLUSTER_EDGE="$edge"
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

# mt_is_local_edge — true on a developer box (cluster.edge: local): no public
# DNS, no public certificates, no Headscale mesh. Gate callers must log WHY they
# skip ("edge local: ...") — the reason is the edge, never an empty token.
mt_is_local_edge() {
  mt_load_cluster_platform
  [ "$MT_CLUSTER_EDGE" = "local" ]
}

# mt_ingress_public_ip — print the public IPv4 clients use to reach the
# ingress. k3s: cluster.public_ip (127.0.0.1 on edge: local). LKE: the ingress Service's LoadBalancer IP
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

# mt_coredns_custom_suffix — key suffix for entries in kube-system/coredns-custom
# that must be imported INSIDE the cluster's main server block (e.g. `rewrite`
# rules). LKE's Corefile imports `custom/*.include` there; k3s's imports
# `custom/*.override` there (its `*.server` keys are separate server blocks).
mt_coredns_custom_suffix() {
  mt_load_cluster_platform
  if [ "$MT_CLUSTER_PLATFORM" = "k3s" ]; then
    printf 'override\n'
  else
    printf 'include\n'
  fi
}
