#!/usr/bin/env bash
#
# Discover the *node* ExternalIP for a given pod and namespace.
# Intended for:
# - validating JVB placement/networking
# - reusing the same discovery logic we embed in the JVB initContainer
#
# Usage:
#   KUBECONFIG=... ./apps/scripts/jitsi-discover-node-external-ip.sh <namespace> <pod-name>
#
# Output:
#   Prints a single IPv4 ExternalIP to stdout on success.
#
set -euo pipefail

if [ "${#}" -ne 2 ]; then
  echo "Usage: $0 <namespace> <pod-name>" >&2
  exit 2
fi

NS="$1"
POD="$2"

NODE_NAME="$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}')"
if [ -z "$NODE_NAME" ]; then
  echo "ERROR: could not determine nodeName for pod $NS/$POD" >&2
  exit 1
fi

# ExternalIP can be empty on some providers/clusters; for JVB hostPort, we treat that as fatal.
EXTERNAL_IPS="$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' || true)"
EXTERNAL_IP="$(echo "$EXTERNAL_IPS" | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"

if [ -z "$EXTERNAL_IP" ]; then
  echo "ERROR: node $NODE_NAME has no IPv4 ExternalIP in .status.addresses[].type==ExternalIP" >&2
  echo "DEBUG: raw ExternalIP addresses: ${EXTERNAL_IPS:-<empty>}" >&2
  echo "DEBUG: node addresses:" >&2
  kubectl get node "$NODE_NAME" -o jsonpath='{range .status.addresses[*]}{.type}={.address}{"\n"}{end}' >&2 || true
  exit 1
fi

echo "$EXTERNAL_IP"

