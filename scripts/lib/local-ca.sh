#!/bin/bash
# Local certificate authority for a developer box (cluster.edge: local).
#
# A devbox has no public names, so Let's Encrypt cannot issue for it. Instead
# `scripts/devbox init` creates a per-developer CA with mkcert (trusted by the
# developer's host and browsers), and the deploy scripts make cert-manager
# issue every certificate from it — under the SAME issuer names the public
# environments use (letsencrypt-prod, letsencrypt-prod-dns01,
# letsencrypt-dns01-<tenant>), so every ingress annotation, Certificate and
# reflector annotation deploys unchanged.
#
# The CA key lives in the developer's gitignored .devbox/ca/ and in one Secret
# in the cert-manager namespace (cert-manager's cluster resource namespace,
# where ClusterIssuers look up their CA Secret). It is throwaway.
#
# Infra config (local edge only):
#   tls:
#     local_ca:
#       cert: ca/rootCA.pem       # relative paths resolve against the infra config's directory
#       key:  ca/rootCA-key.pem
#
# Usage:
#   source "${REPO_ROOT}/scripts/lib/local-ca.sh"
#   mt_local_ca_apply_secret                      # deploy_infra: CA files -> Secret
#   mt_local_ca_apply_cluster_issuers <name>...   # CA ClusterIssuers (Secret must exist)
#   mt_local_ca_publish_configmap <namespace>     # CA certificate (never the key) as ConfigMap mt-local-ca
#   mt_local_ca_trust <manifest> <container> <env>...  # mount it into a Deployment, point <env> at it
#
# Pointing SSL_CERT_FILE at the CA would replace a container's public roots.
# Pass SSL_CERT_DIR instead: it gets the mount directory, where the CA also
# sits under its OpenSSL hash name, so OpenSSL-based clients (Python ssl,
# PHP, curl) trust it IN ADDITION to their built-in bundle.

MT_LOCAL_CA_SECRET="mt-local-ca"

# _mt_local_ca_path <value> — resolve a tls.local_ca.* path against the infra
# config directory unless it is absolute.
_mt_local_ca_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s\n' "${MT_INFRA_CONFIG%/*}/$1" ;;
  esac
}

# mt_local_ca_apply_secret — read tls.local_ca.{cert,key} from the infra config,
# check they are a CA certificate and its matching key, and apply them as the
# kubernetes.io/tls Secret $MT_LOCAL_CA_SECRET in $NS_CERTMANAGER. Fails on any
# missing or inconsistent input: a devbox without its CA cannot serve TLS.
mt_local_ca_apply_secret() {
  : "${MT_INFRA_CONFIG:?MT_INFRA_CONFIG is required to find tls.local_ca}"
  : "${NS_CERTMANAGER:?NS_CERTMANAGER is required}"
  local cert key
  cert=$(yq '.tls.local_ca.cert // ""' "$MT_INFRA_CONFIG")
  key=$(yq '.tls.local_ca.key // ""' "$MT_INFRA_CONFIG")
  if [ -z "$cert" ] || [ -z "$key" ]; then
    print_error "edge local needs tls.local_ca.cert and tls.local_ca.key in $MT_INFRA_CONFIG (run: scripts/devbox init)"
    return 1
  fi
  cert=$(_mt_local_ca_path "$cert")
  key=$(_mt_local_ca_path "$key")
  [ -f "$cert" ] || { print_error "Local CA certificate not found: $cert"; return 1; }
  [ -f "$key" ]  || { print_error "Local CA key not found: $key"; return 1; }
  if ! openssl x509 -in "$cert" -noout -text 2>/dev/null | grep -q 'CA:TRUE'; then
    print_error "$cert is not a CA certificate (no basicConstraints CA:TRUE)"
    return 1
  fi
  # Only a name-constrained CA may go into the cluster: its key in a Secret
  # must not be able to mint certificates for real domains (an unconstrained
  # mkcert root trusted by the host would be exactly that).
  if ! openssl x509 -in "$cert" -noout -ext nameConstraints 2>/dev/null | grep -q 'DNS:localhost'; then
    print_error "$cert has no nameConstraints limiting it to DNS:localhost — use the CA from scripts/devbox init"
    return 1
  fi
  local cert_pub key_pub
  cert_pub=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null)
  key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null)
  if [ -z "$cert_pub" ] || [ "$cert_pub" != "$key_pub" ]; then
    print_error "Local CA key $key does not match certificate $cert"
    return 1
  fi
  mt_apply kubectl apply -f <(kubectl create secret tls "$MT_LOCAL_CA_SECRET" -n "$NS_CERTMANAGER" \
    --cert="$cert" --key="$key" --dry-run=client -o yaml)
  print_status "Local CA Secret $NS_CERTMANAGER/$MT_LOCAL_CA_SECRET applied ($(openssl x509 -in "$cert" -noout -subject 2>/dev/null))"
}

# mt_local_ca_apply_cluster_issuers <name>... — apply each name as a CA
# ClusterIssuer signing with $MT_LOCAL_CA_SECRET. The Secret must already exist
# (deploy_infra creates it); a missing Secret is an error, not a skip.
mt_local_ca_apply_cluster_issuers() {
  : "${NS_CERTMANAGER:=infra-cert-manager}"
  [ "$#" -gt 0 ] || { print_error "mt_local_ca_apply_cluster_issuers: no issuer names"; return 1; }
  if ! kubectl get secret "$MT_LOCAL_CA_SECRET" -n "$NS_CERTMANAGER" >/dev/null 2>&1; then
    print_error "Local CA Secret $NS_CERTMANAGER/$MT_LOCAL_CA_SECRET is missing — run deploy_infra first"
    return 1
  fi
  local name
  for name in "$@"; do
    [[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { print_error "Invalid issuer name '$name'"; return 1; }
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${name}
  labels:
    mothertree.io/issuer: local-ca
spec:
  ca:
    secretName: ${MT_LOCAL_CA_SECRET}
EOF
  done
  for name in "$@"; do
    kubectl wait --for=condition=Ready "clusterissuer/${name}" --timeout=60s >/dev/null \
      || { print_error "ClusterIssuer $name (local CA) did not become Ready"; return 1; }
  done
  print_status "Local CA ClusterIssuers ready: $*"
}

MT_LOCAL_CA_CONFIGMAP="mt-local-ca"
MT_LOCAL_CA_MOUNT="/etc/mt-local-ca"

# mt_local_ca_publish_configmap <namespace> — copy the local CA's certificate
# (tls.crt of the $MT_LOCAL_CA_SECRET Secret; the key never leaves
# $NS_CERTMANAGER) into ConfigMap $MT_LOCAL_CA_CONFIGMAP (key ca.crt) in
# <namespace>, for pods that call another devbox host over HTTPS. The same
# certificate is also stored as <subject-hash>.0, OpenSSL's lookup name, so
# the mount works as an SSL_CERT_DIR.
mt_local_ca_publish_configmap() {
  local ns="${1:?mt_local_ca_publish_configmap: namespace required}" crt hash
  : "${NS_CERTMANAGER:=infra-cert-manager}"
  crt=$(kubectl get secret "$MT_LOCAL_CA_SECRET" -n "$NS_CERTMANAGER" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if ! printf '%s\n' "$crt" | openssl x509 -noout 2>/dev/null; then
    print_error "Local CA Secret $NS_CERTMANAGER/$MT_LOCAL_CA_SECRET is missing or has no certificate — run deploy_infra first"
    return 1
  fi
  hash=$(printf '%s\n' "$crt" | openssl x509 -noout -hash)
  mt_apply kubectl apply -f <(kubectl create configmap "$MT_LOCAL_CA_CONFIGMAP" -n "$ns" \
    --from-literal=ca.crt="$crt" --from-literal="${hash}.0"="$crt" --dry-run=client -o yaml)
}

# mt_local_ca_trust <manifest-file> <container> <env-var>... — edit a rendered
# Deployment manifest in place: mount ConfigMap $MT_LOCAL_CA_CONFIGMAP at
# $MT_LOCAL_CA_MOUNT in <container> and set each <env-var> to the CA file
# (e.g. AWS_CA_BUNDLE for boto3). Fails if the container is not found.
mt_local_ca_trust() {
  local file="${1:?manifest file required}" container="${2:?container name required}"
  shift 2
  [ "$#" -gt 0 ] || { print_error "mt_local_ca_trust: no env var names"; return 1; }
  local var
  for var in "$@"; do
    [[ "$var" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { print_error "mt_local_ca_trust: invalid env var name '$var'"; return 1; }
  done
  if [ "$(C="$container" yq 'select(.kind == "Deployment") | [.spec.template.spec.containers[] | select(.name == strenv(C))] | length' "$file")" != "1" ]; then
    print_error "mt_local_ca_trust: no single container '$container' in a Deployment in $file"
    return 1
  fi
  C="$container" CM="$MT_LOCAL_CA_CONFIGMAP" MP="$MT_LOCAL_CA_MOUNT" yq -i '
    (select(.kind == "Deployment") | .spec.template.spec.volumes) += [{"name": "mt-local-ca", "configMap": {"name": strenv(CM)}}] |
    (select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == strenv(C)) | .volumeMounts) += [{"name": "mt-local-ca", "mountPath": strenv(MP), "readOnly": true}]
  ' "$file"
  local val
  for var in "$@"; do
    val="$MT_LOCAL_CA_MOUNT/ca.crt"
    [ "$var" = "SSL_CERT_DIR" ] && val="$MT_LOCAL_CA_MOUNT"
    C="$container" V="$var" F="$val" yq -i '
      (select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == strenv(C)) | .env) += [{"name": strenv(V), "value": strenv(F)}]
    ' "$file"
  done
}
