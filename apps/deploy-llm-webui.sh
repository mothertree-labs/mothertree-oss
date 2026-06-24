#!/bin/bash

# Deploy Open WebUI for a tenant (per-tenant LLM chat UI with Keycloak OIDC)
# Uses shared Ollama inference engine in infra-llm namespace.
#
# Usage:
#   ./apps/deploy-llm-webui.sh -e <env> -t <tenant>

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy Open WebUI for a tenant (Keycloak OIDC auth, shared Ollama)."
    echo ""
    echo "Options:"
    echo "  -e <env>       Environment (e.g., dev, prod)"
    echo "  -t <tenant>    Tenant name (e.g., example)"
    echo "  -h, --help     Show this help"
}

mt_parse_args "$@"
mt_require_env
mt_require_tenant

source "${REPO_ROOT}/scripts/lib/config.sh"
mt_load_tenant_config

source "${REPO_ROOT}/scripts/lib/notify.sh"
mt_deploy_start "deploy-llm-webui"

mt_require_commands kubectl yq envsubst curl jq

print_status "Deploying Open WebUI for $MT_TENANT ($MT_ENV)"
print_status "  Namespace: $NS_LLM"
print_status "  Host:      $LLM_HOST"
print_status "  Auth:      $AUTH_HOST/realm/$TENANT_KEYCLOAK_REALM"

# Validate required variables and secrets
if [ "${LLM_ENABLED:-false}" != "true" ]; then
    print_warning "LLM is not enabled for $MT_TENANT (features.llm_enabled != true) — skipping"
    exit 0
fi

if [ -z "${LLM_OIDC_CLIENT_SECRET:-}" ] || [ "$LLM_OIDC_CLIENT_SECRET" = "null" ]; then
    print_error "LLM_OIDC_CLIENT_SECRET not set. Add oidc.open_webui_client_secret to tenant secrets."
    exit 1
fi

# Load Keycloak admin password (needed to create/update the OIDC client)
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
    KEYCLOAK_ADMIN_PASSWORD=$(yq '.keycloak.admin_password // ""' "$TENANT_SECRETS" 2>/dev/null)
fi
if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ] || [ "$KEYCLOAK_ADMIN_PASSWORD" = "null" ]; then
    print_error "KEYCLOAK_ADMIN_PASSWORD is required. Set keycloak.admin_password in tenant secrets."
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Ensure namespace exists
# ---------------------------------------------------------------------------
mt_reset_change_tracker
print_status "Ensuring $NS_LLM namespace exists..."
kubectl create namespace "$NS_LLM" --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# 2. Setup Open WebUI OIDC client in Keycloak
# ---------------------------------------------------------------------------
print_status "Setting up Open WebUI OIDC client in Keycloak realm $TENANT_KEYCLOAK_REALM..."

# Access Keycloak through kubectl port-forward (avoids ingress TLS issues).
LOCAL_PORT=$((RANDOM + 10000))
print_status "Setting up port-forward to Keycloak on port ${LOCAL_PORT}..."
kubectl -n "$NS_AUTH" port-forward svc/keycloak-keycloakx-http ${LOCAL_PORT}:80 > /tmp/keycloak-pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

KEYCLOAK_URL="http://localhost:${LOCAL_PORT}"

# Get admin token
TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    --data-urlencode "username=admin" \
    --data-urlencode "password=$KEYCLOAK_ADMIN_PASSWORD" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" | jq -r '.access_token')

if [ "$TOKEN" = "null" ] || [ -z "$TOKEN" ]; then
    print_error "Failed to get Keycloak admin token"
    exit 1
fi

# Check if client exists
EXISTING_CLIENT=$(curl -s "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients?clientId=open-webui" \
    -H "Authorization: Bearer $TOKEN")
CLIENT_COUNT=$(echo "$EXISTING_CLIENT" | jq 'length')

CLIENT_CONFIG='{
    "clientId": "open-webui",
    "name": "Open WebUI",
    "enabled": true,
    "protocol": "openid-connect",
    "publicClient": false,
    "secret": "'"$LLM_OIDC_CLIENT_SECRET"'",
    "standardFlowEnabled": true,
    "directAccessGrantsEnabled": false,
    "serviceAccountsEnabled": false,
    "redirectUris": [
        "https://'"$LLM_HOST"'/*"
    ],
    "webOrigins": [
        "https://'"$LLM_HOST"'"
    ],
    "attributes": {
        "pkce.code.challenge.method": "S256"
    }
}'

if [ "$CLIENT_COUNT" -gt 0 ]; then
    print_status "Updating existing open-webui client..."
    CLIENT_UUID=$(echo "$EXISTING_CLIENT" | jq -r '.[0].id')
    curl -s -X PUT "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients/$CLIENT_UUID" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$CLIENT_CONFIG" > /dev/null
else
    print_status "Creating new open-webui client..."
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/clients" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$CLIENT_CONFIG" > /dev/null
fi
print_success "Open WebUI OIDC client configured"

# Kill the port-forward — no longer needed
kill $PF_PID 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Create K8s Secret
# ---------------------------------------------------------------------------
print_status "Creating OIDC client secret in K8s..."
mt_apply kubectl apply -f <(kubectl create secret generic open-webui-oidc \
    -n "$NS_LLM" \
    --from-literal=client-secret="$LLM_OIDC_CLIENT_SECRET" \
    --dry-run=client -o yaml)

# ---------------------------------------------------------------------------
# 4. Ensure Keycloak auth ingress (external) for this tenant
#
# The OIDC flow redirects the browser to $AUTH_HOST (Keycloak). The external
# ingress must exist so the public NodeBalancer routes the request to Keycloak
# with the proper wildcard TLS cert. The template is also used by
# deploy-matrix.sh — we apply it here so deploy-llm-webui.sh is self-sufficient.
# =============================================================================
print_status "Ensuring external Keycloak ingress for $AUTH_HOST..."
envsubst '${AUTH_HOST} ${TENANT} ${NS_AUTH} ${TENANT_DOMAIN} ${TENANT_NAME}' \
    < "$REPO_ROOT/apps/manifests/keycloak/tenant-auth-ingress.yaml.tpl" \
    | kubectl apply -f -
print_success "External Keycloak ingress configured for $AUTH_HOST"

# ---------------------------------------------------------------------------
# 5. Ensure Keycloak internal ingress for this tenant
#
# Open WebUI's backend fetches OIDC metadata from $AUTH_HOST server-side.
# The CoreDNS rewrite below routes these requests to the internal ingress
# controller. That controller needs a matching ingress with the wildcard TLS
# cert — otherwise it serves its default (fake) cert and the Python HTTPX
# client rejects the connection.
# =============================================================================
print_status "Ensuring internal Keycloak ingress for $AUTH_HOST..."
if ! kubectl -n "$NS_AUTH" get ingress "keycloak-internal-${MT_TENANT}" >/dev/null 2>&1; then
    kubectl apply -f - <<INGRESS
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "8"
  labels:
    app: keycloak
    purpose: internal-oidc
    tenant: ${MT_TENANT}
  name: keycloak-internal-${MT_TENANT}
  namespace: ${NS_AUTH}
spec:
  ingressClassName: nginx-internal
  rules:
  - host: ${AUTH_HOST}
    http:
      paths:
      - backend:
          service:
            name: keycloak-keycloakx-http
            port:
              name: http
        path: /
        pathType: Prefix
  tls:
  - hosts:
    - ${AUTH_HOST}
    secretName: wildcard-tls-${TENANT_NAME}
INGRESS
    print_success "Internal Keycloak ingress created for $AUTH_HOST"
else
    print_status "Internal Keycloak ingress already exists for $AUTH_HOST"
fi

# ---------------------------------------------------------------------------
# 6. CoreDNS rewrite for AUTH_HOST → internal ingress
#
# The CoreDNS rewrite makes $AUTH_HOST resolve to the internal ingress
# controller IP, keeping server-side OIDC metadata requests in-cluster and
# avoiding hairpin connections through the public NodeBalancer.
#
# Follows the same pattern as deploy-stalwart.sh's mail rewrite.
# =============================================================================
print_status "Ensuring CoreDNS rewrite for $AUTH_HOST → internal ingress"
if ! kubectl -n kube-system get configmap coredns-custom >/dev/null 2>&1; then
    kubectl -n kube-system create configmap coredns-custom
fi
_coredns_key="auth-${MT_TENANT}.include"
_coredns_target="ingress-nginx-internal-controller.infra-ingress-internal.svc.cluster.local"
_coredns_body="rewrite name ${AUTH_HOST} ${_coredns_target}"$'\n'

_coredns_existing=$(kubectl -n kube-system get configmap coredns-custom \
    -o "jsonpath={.data.${_coredns_key}}" 2>/dev/null || true)
if [ "$_coredns_existing" = "$_coredns_body" ]; then
    print_status "CoreDNS rewrite already in place — skipping patch + rollout"
    _coredns_changed=false
else
    _coredns_patch=$(jq -cn \
        --arg key "$_coredns_key" \
        --arg body "$_coredns_body" \
        '{data: {($key): $body}}')
    kubectl -n kube-system patch configmap coredns-custom --type=merge -p "$_coredns_patch"
    print_success "CoreDNS rewrite applied"
    _coredns_changed=true
fi

if [ "$_coredns_changed" = "true" ]; then
    _coredns_deploy=$(kubectl -n kube-system get deploy -l k8s-app=kube-dns -o name | head -n1)
    if [ -z "$_coredns_deploy" ]; then
        print_error "No CoreDNS deployment found in kube-system (label k8s-app=kube-dns)"
        exit 1
    fi
    print_status "Restarting $_coredns_deploy to propagate rewrite to all replicas"
    kubectl -n kube-system rollout restart "$_coredns_deploy"
    kubectl -n kube-system rollout status "$_coredns_deploy" --timeout=180s

    if kubectl -n kube-system get ds node-local-dns >/dev/null 2>&1; then
        print_status "Restarting node-local-dns DaemonSet to flush per-node caches"
        kubectl -n kube-system rollout restart ds/node-local-dns
        kubectl -n kube-system rollout status ds/node-local-dns --timeout=180s
    fi
fi

# Verify the rewrite propagated to all CoreDNS replicas
print_status "Verifying CoreDNS rewrite propagated to ALL replicas"
_auth_cluster_ip=$(kubectl -n infra-ingress-internal get svc ingress-nginx-internal-controller \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [ -z "$_auth_cluster_ip" ]; then
    print_warning "Could not read internal ingress ClusterIP — skipping per-replica verification"
    print_warning "  (the rewrite rule is applied; CoreDNS reloaded; DNS will converge)"
else
    _coredns_pod_ips=$(kubectl -n kube-system get pods -l k8s-app=kube-dns -o json \
        | jq -r '.items[]
            | select(.status.phase == "Running")
            | select(.metadata.deletionTimestamp == null)
            | .status.podIP' \
        | tr '\n' ' ')
    if [ -z "${_coredns_pod_ips// /}" ]; then
        print_warning "No running CoreDNS pods found — skipping per-replica verification"
    else
        print_status "Expecting $AUTH_HOST → $_auth_cluster_ip from CoreDNS pods: $_coredns_pod_ips"
        _dns_probe_pod="auth-dns-probe-$$"
        if kubectl run "$_dns_probe_pod" -n "$NS_LLM" \
            --rm -i --restart=Never --image=busybox:1.36 --quiet \
            --command -- sh -c "
                pod_ips='${_coredns_pod_ips}'
                want='${_auth_cluster_ip}'
                host='${AUTH_HOST}'
                for i in \$(seq 1 18); do
                    all_ok=1
                    last_state=
                    for ip in \$pod_ips; do
                        got=\$(nslookup \"\$host\" \"\$ip\" 2>/dev/null | awk '/^Name:/{f=1; next} f && /^Address/{print \$2; exit}')
                        if [ \"\$got\" != \"\$want\" ]; then
                            all_ok=0
                            last_state=\"replica \$ip returned '\$got'\"
                        fi
                    done
                    if [ \"\$all_ok\" = '1' ]; then
                        echo \"OK: all CoreDNS replicas return \$want for \$host\"
                        exit 0
                    fi
                    echo \"  attempt \$i: \$last_state (want \$want), retrying in 5s\"
                    sleep 5
                done
                echo \"FAIL: not all CoreDNS replicas converged on \$want for \$host within 90s (\$last_state)\"
                exit 1
            "; then
            print_success "CoreDNS rewrite verified across all replicas: $AUTH_HOST → $_auth_cluster_ip"
        else
            print_error "CoreDNS rewrite for $AUTH_HOST did not propagate to all replicas within 90s"
            print_error "Check kube-system/coredns-custom ConfigMap and CoreDNS pod logs:"
            print_error "  kubectl -n kube-system get configmap coredns-custom -o yaml"
            print_error "  kubectl -n kube-system logs -l k8s-app=kube-dns --tail=100"
            exit 1
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 5. Apply Open WebUI manifests
# ---------------------------------------------------------------------------
print_status "Applying Open WebUI manifests..."
export LLM_MODEL
# Resolve infra config path to read LLM_MODEL
_mt_resolve_infra_config "$MT_ENV" 2>/dev/null || true
if [ -n "$MT_INFRA_CONFIG" ] && [ -f "$MT_INFRA_CONFIG" ]; then
  LLM_MODEL=$(yq '.llm.model // "llama3.2:1b"' "$MT_INFRA_CONFIG")
else
  LLM_MODEL="llama3.2:1b"
fi

# Choose volume type based on environment.
# Dev: emptyDir is fine (ephemeral, matches Linode block-storage cap).
# Prod: PVC survives restarts and avoids conversation data loss.
if [ "$MT_ENV" = "prod" ]; then
    LLM_WEBUI_STORAGE_VALUE="persistentVolumeClaim:
            claimName: llm-data-${MT_TENANT}"
    print_status "Creating PVC for Open WebUI data (${LLM_STORAGE_SIZE})..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: llm-data-${MT_TENANT}
  namespace: ${NS_LLM}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${LLM_STORAGE_SIZE}
EOF
else
    LLM_WEBUI_STORAGE_VALUE="emptyDir: {}"
fi
export LLM_WEBUI_STORAGE_VALUE

mt_apply kubectl apply -f <(envsubst < "${REPO_ROOT}/apps/manifests/llm/open-webui-tenant.yaml.tpl")

# ---------------------------------------------------------------------------
# 6. Deploy HPA for Open WebUI auto-scaling (only if min != max replicas)
# ---------------------------------------------------------------------------
if [ "$LLM_MIN_REPLICAS" != "$LLM_MAX_REPLICAS" ]; then
    print_status "Deploying HPA for Open WebUI..."
    envsubst < "$REPO_ROOT/apps/manifests/llm/open-webui-hpa.yaml.tpl" | kubectl apply -f -
    print_success "Open WebUI HPA deployed (CPU 80% threshold)"
else
    kubectl delete hpa open-webui-hpa -n "$NS_LLM" --ignore-not-found >/dev/null 2>&1
    print_status "Open WebUI: fixed replicas ($LLM_MIN_REPLICAS), HPA removed"
fi

# ---------------------------------------------------------------------------
# 7. Wait for rollout
# ---------------------------------------------------------------------------
print_status "Waiting for Open WebUI deployment to roll out..."
kubectl rollout status deployment/open-webui -n "$NS_LLM" --timeout=120s || {
    print_warning "Open WebUI rollout not ready within timeout — dumping pod diagnostics"
    mt_reset_change_tracker
    dump_pod_diagnostics "$NS_LLM" "app=open-webui"
}

# ---------------------------------------------------------------------------
# 8. Verification
# ---------------------------------------------------------------------------
print_status "Verifying Open WebUI pod..."
kubectl get pods -n "$NS_LLM"

# Check that the OIDC discovery endpoint resolves
print_status "Verifying OpenID Connect discovery..."
kubectl run -n "$NS_LLM" --rm -i --restart=Never llm-oidc-check \
    --image=curlimages/curl:8.12.1 \
    -- curl -sf "https://$AUTH_HOST/realms/$TENANT_KEYCLOAK_REALM/.well-known/openid-configuration" \
    > /dev/null 2>&1 && \
    print_success "OIDC discovery endpoint reachable" || \
    print_warning "OIDC discovery not reachable from inside cluster (expected if Keycloak ingress uses auth.dev.*)"

# Restart if changes were detected
mt_restart_if_changed deployment/open-webui -n "$NS_LLM"

print_success "Open WebUI deployed for $MT_TENANT!"
print_success "  URL:  https://${LLM_HOST}"
print_success "  Auth: Keycloak realm $TENANT_KEYCLOAK_REALM via $AUTH_HOST"
