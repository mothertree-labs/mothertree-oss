#!/bin/bash

# Deploy Jitsi Meet using static Kubernetes manifests
# This script applies environment-specific Jitsi manifests using envsubst
#
# Namespace structure:
#   - Jitsi in NS_JITSI (tenant-prefixed namespace, e.g., 'tn-example-jitsi')
#
# Usage:
#   ./apps/deploy-jitsi.sh -e dev -t example

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy Jitsi Meet for a tenant."
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
mt_deploy_start "deploy-jitsi"

mt_require_commands kubectl envsubst openssl

print_status "Deploying Jitsi Meet for environment: $MT_ENV"
print_status "Tenant: $TENANT"
print_status "Jitsi namespace: $NS_JITSI"
print_status "Using environment: JITSI_HOST=$JITSI_HOST, AUTH_HOST=$AUTH_HOST"

# Validate required secrets
export JWT_APP_SECRET="${TF_VAR_jitsi_jwt_app_secret}"
if [ -z "${JWT_APP_SECRET:-}" ]; then
    print_error "TF_VAR_jitsi_jwt_app_secret not set in tenant secrets"
    print_error "Generate one with: openssl rand -hex 32"
    exit 1
fi

if [ -z "${TURN_SHARED_SECRET:-}" ]; then
    print_error "TURN_SHARED_SECRET not set. Set turn.shared_secret in tenant secrets."
    exit 1
fi

# Validate TURN server IP
if [ -z "${TURN_SERVER_IP:-}" ]; then
    print_error "TURN server IP not available. Ensure phase1 has been applied."
    exit 1
fi
print_status "TURN server IP: $TURN_SERVER_IP"

# Validate JVB port
if [ -z "$JVB_PORT" ] || [ "$JVB_PORT" = "null" ]; then
    print_error "jvb_port not configured in tenant config"
    print_error "Add 'resources.jitsi.jvb_port: <port>' to the tenant config (e.g., 31000)"
    exit 1
fi
print_status "JVB port: $JVB_PORT (hostPort for UDP media, IP discovered dynamically via Downward API)"

# Ensure namespace exists
print_status "Ensuring $NS_JITSI namespace exists..."
kubectl create namespace "$NS_JITSI" --dry-run=client -o yaml | kubectl apply -f -
print_success "Namespace ready: $NS_JITSI"

# Generate Jitsi secrets at deploy time with strong random passwords
# If the secret already exists, retrieve existing passwords to avoid breaking running services.
# Otherwise, generate new strong random passwords.
print_status "Creating/updating jitsi-secrets with strong random passwords..."

if kubectl get secret jitsi-secrets -n "$NS_JITSI" &>/dev/null; then
    print_status "Existing jitsi-secrets found, preserving current passwords..."
    JICOFO_AUTH_PASSWORD=$(kubectl get secret jitsi-secrets -n "$NS_JITSI" -o jsonpath='{.data.JICOFO_AUTH_PASSWORD}' | base64 -d)
    JICOFO_COMPONENT_SECRET=$(kubectl get secret jitsi-secrets -n "$NS_JITSI" -o jsonpath='{.data.JICOFO_COMPONENT_SECRET}' | base64 -d)
    JVB_AUTH_PASSWORD=$(kubectl get secret jitsi-secrets -n "$NS_JITSI" -o jsonpath='{.data.JVB_AUTH_PASSWORD}' | base64 -d)
    JIGASI_AUTH_PASSWORD=$(kubectl get secret jitsi-secrets -n "$NS_JITSI" -o jsonpath='{.data.JIGASI_AUTH_PASSWORD}' | base64 -d)
    JIGASI_COMPONENT_SECRET=$(kubectl get secret jitsi-secrets -n "$NS_JITSI" -o jsonpath='{.data.JIGASI_COMPONENT_SECRET}' | base64 -d)
    JIBRI_AUTH_PASSWORD=$(kubectl get secret jitsi-secrets -n "$NS_JITSI" -o jsonpath='{.data.JIBRI_AUTH_PASSWORD}' | base64 -d)
    JIBRI_RECORDER_PASSWORD=$(kubectl get secret jitsi-secrets -n "$NS_JITSI" -o jsonpath='{.data.JIBRI_RECORDER_PASSWORD}' | base64 -d)

    # Regenerate any password that is empty or trivially weak (matches known weak defaults)
    WEAK_PASSWORDS="jicofo-password jicofo-secret jvb-password jigasi-password jigasi-secret jibri.password jibri.recorder"
    for var_name in JICOFO_AUTH_PASSWORD JICOFO_COMPONENT_SECRET JVB_AUTH_PASSWORD JIGASI_AUTH_PASSWORD JIGASI_COMPONENT_SECRET JIBRI_AUTH_PASSWORD JIBRI_RECORDER_PASSWORD; do
        val="${!var_name}"
        if [ -z "$val" ] || echo "$WEAK_PASSWORDS" | grep -qw "$val"; then
            new_val=$(openssl rand -base64 24)
            eval "$var_name='$new_val'"
            print_warning "Regenerated weak/empty $var_name"
        fi
    done
else
    print_status "No existing jitsi-secrets found, generating new strong passwords..."
    JICOFO_AUTH_PASSWORD=$(openssl rand -base64 24)
    JICOFO_COMPONENT_SECRET=$(openssl rand -base64 24)
    JVB_AUTH_PASSWORD=$(openssl rand -base64 24)
    JIGASI_AUTH_PASSWORD=$(openssl rand -base64 24)
    JIGASI_COMPONENT_SECRET=$(openssl rand -base64 24)
    JIBRI_AUTH_PASSWORD=$(openssl rand -base64 24)
    JIBRI_RECORDER_PASSWORD=$(openssl rand -base64 24)
fi

kubectl create secret generic jitsi-secrets \
    --namespace="$NS_JITSI" \
    --from-literal=JICOFO_AUTH_PASSWORD="$JICOFO_AUTH_PASSWORD" \
    --from-literal=JICOFO_COMPONENT_SECRET="$JICOFO_COMPONENT_SECRET" \
    --from-literal=JVB_AUTH_PASSWORD="$JVB_AUTH_PASSWORD" \
    --from-literal=JIGASI_AUTH_PASSWORD="$JIGASI_AUTH_PASSWORD" \
    --from-literal=JIGASI_COMPONENT_SECRET="$JIGASI_COMPONENT_SECRET" \
    --from-literal=JIBRI_AUTH_PASSWORD="$JIBRI_AUTH_PASSWORD" \
    --from-literal=JIBRI_RECORDER_PASSWORD="$JIBRI_RECORDER_PASSWORD" \
    --from-literal=JWT_APP_SECRET="$JWT_APP_SECRET" \
    --from-literal=TURN_SHARED_SECRET="$TURN_SHARED_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -
print_success "jitsi-secrets created/updated with strong passwords, JWT_APP_SECRET, and TURN_SHARED_SECRET"

# Apply templated manifests with environment variables
print_status "Applying templated Jitsi manifests..."

# Apply Keycloak adapter ConfigMaps (non-templated) with namespace substitution
print_status "Applying Keycloak adapter static files..."
cat "$REPO_ROOT/apps/manifests/jitsi/adapter-static-files.yaml" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -

print_status "Applying custom meet.conf template..."
cat "$REPO_ROOT/apps/manifests/jitsi/meet-conf-template.yaml" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -

# Apply Keycloak adapter deployment (templated) with namespace substitution
print_status "Applying Keycloak adapter deployment..."
envsubst < "$REPO_ROOT/apps/manifests/jitsi/keycloak-adapter.yaml.tpl" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -

# Apply services and deployments with namespace substitution
envsubst < "$REPO_ROOT/apps/manifests/jitsi/web.yaml.tpl" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -
envsubst < "$REPO_ROOT/apps/manifests/jitsi/prosody.yaml.tpl" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -
# Force StatefulSet rollout restart to ensure pods pick up spec changes.
# StatefulSets with CrashLoopBackOff pods may not auto-restart on apply.
kubectl rollout restart statefulset/jitsi-prosody -n "$NS_JITSI"
# Delete existing pod if stuck in CrashLoopBackOff so the controller creates a new one
if kubectl get pod jitsi-prosody-0 -n "$NS_JITSI" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null | grep -q "CrashLoopBackOff"; then
    print_warning "Prosody pod stuck in CrashLoopBackOff — deleting to force recreation with new spec"
    kubectl delete pod jitsi-prosody-0 -n "$NS_JITSI" --grace-period=0 --force 2>/dev/null || true
fi
# JVB uses specific variable substitution to preserve shell variables in init container scripts
# NS_JITSI is included for tenant-specific ClusterRole/ClusterRoleBinding names (avoids multi-tenant RBAC collision)
envsubst '${JVB_PORT} ${JITSI_HOST} ${TURN_SERVER_IP} ${JVB_MIN_REPLICAS} ${NS_JITSI}' < "$REPO_ROOT/apps/manifests/jitsi/jvb.yaml.tpl" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -
# Clean up old non-namespaced RBAC resources (replaced by tenant-specific names)
kubectl delete clusterrole jitsi-jvb-node-reader --ignore-not-found >/dev/null 2>&1
kubectl delete clusterrolebinding jitsi-jvb-node-reader --ignore-not-found >/dev/null 2>&1
envsubst < "$REPO_ROOT/apps/manifests/jitsi/jicofo.yaml.tpl" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -

# Restart Jicofo after Prosody so it rejoins the brewery MUC with a fresh XMPP connection.
# Without this, Jicofo can fail to rejoin the brewery after a Prosody restart,
# leaving it unable to discover JVB bridges (calls fail with "no bridge available").
print_status "Waiting for Prosody to be ready before restarting Jicofo..."
kubectl wait --for=condition=ready pod/jitsi-prosody-0 -n "$NS_JITSI" --timeout=60s 2>/dev/null || true
kubectl rollout restart deployment/jitsi-jicofo -n "$NS_JITSI"
kubectl rollout status deployment/jitsi-jicofo -n "$NS_JITSI" --timeout=60s 2>/dev/null || true

# Wait for Jicofo to discover JVB bridges (up to 30s)
print_status "Waiting for Jicofo to discover JVB bridges..."
for i in $(seq 1 15); do
    BRIDGE_COUNT=$(kubectl exec -n "$NS_JITSI" deployment/jitsi-jicofo -- \
        curl -sf http://localhost:8888/stats 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('bridge_selector',{}).get('bridge_count',0))" 2>/dev/null)
    if [ "${BRIDGE_COUNT:-0}" -gt 0 ]; then
        print_success "Jicofo found $BRIDGE_COUNT bridge(s)"
        break
    fi
    sleep 2
done
if [ "${BRIDGE_COUNT:-0}" -eq 0 ]; then
    print_warning "Jicofo has not discovered any bridges yet — calls may fail until bridges register"
fi

# Apply templated ConfigMap
envsubst < "$REPO_ROOT/apps/manifests/jitsi/web-config.yaml.tpl" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -

# Apply templated Ingress
envsubst < "$REPO_ROOT/apps/manifests/jitsi/ingress.yaml.tpl" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -

# Deploy metrics exporter (ServiceAccount + Deployment + Service + ConfigMap)
print_status "Deploying Jitsi metrics exporter..."
envsubst < "$REPO_ROOT/apps/manifests/jitsi/jitsi-metrics-exporter.yaml" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -
cat "$REPO_ROOT/apps/manifests/jitsi/jitsi-metrics-exporter-servicemonitor.yaml" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -

# Deploy HorizontalPodAutoscalers (HPA) for auto-scaling (only if min != max replicas)
if [ "$JITSI_WEB_MIN_REPLICAS" != "$JITSI_WEB_MAX_REPLICAS" ]; then
  print_status "Deploying HPAs for Jitsi web and JVB..."
  envsubst < "$REPO_ROOT/apps/manifests/jitsi/web-hpa.yaml.tpl" | kubectl apply -f -
  envsubst < "$REPO_ROOT/apps/manifests/jitsi/jvb-hpa.yaml.tpl" | kubectl apply -f -
  print_success "Jitsi HPAs deployed (CPU 80% threshold)"
else
  kubectl delete hpa jitsi-web-hpa -n "$NS_JITSI" --ignore-not-found >/dev/null 2>&1
  kubectl delete hpa jitsi-jvb-hpa -n "$NS_JITSI" --ignore-not-found >/dev/null 2>&1
  print_status "Jitsi: fixed replicas, HPAs removed"
fi

print_success "Jitsi manifests applied to namespace $NS_JITSI"

# Wait for deployments to be ready
print_status "Checking Jitsi deployments status..."
READY_COUNT=0
TOTAL_COUNT=0

if kubectl get deployment jitsi-web -n "$NS_JITSI" &>/dev/null; then
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if kubectl wait --for=condition=available deployment/jitsi-web -n "$NS_JITSI" --timeout=10s &>/dev/null; then
    READY_COUNT=$((READY_COUNT + 1))
  fi
fi
if kubectl get statefulset jitsi-prosody -n "$NS_JITSI" &>/dev/null; then
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if kubectl wait --for=condition=ready statefulset/jitsi-prosody -n "$NS_JITSI" --timeout=10s &>/dev/null; then
    READY_COUNT=$((READY_COUNT + 1))
  fi
fi
if kubectl get deployment jitsi-jvb -n "$NS_JITSI" &>/dev/null; then
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if kubectl wait --for=condition=available deployment/jitsi-jvb -n "$NS_JITSI" --timeout=10s &>/dev/null; then
    READY_COUNT=$((READY_COUNT + 1))
  fi
fi
if kubectl get deployment jitsi-jicofo -n "$NS_JITSI" &>/dev/null; then
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if kubectl wait --for=condition=available deployment/jitsi-jicofo -n "$NS_JITSI" --timeout=10s &>/dev/null; then
    READY_COUNT=$((READY_COUNT + 1))
  fi
fi
if kubectl get deployment jitsi-keycloak-adapter -n "$NS_JITSI" &>/dev/null; then
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if kubectl wait --for=condition=available deployment/jitsi-keycloak-adapter -n "$NS_JITSI" --timeout=10s &>/dev/null; then
    READY_COUNT=$((READY_COUNT + 1))
  fi
fi

if [ "$READY_COUNT" -eq "$TOTAL_COUNT" ] && [ "$TOTAL_COUNT" -gt 0 ]; then
  print_success "Jitsi deployments ready ($READY_COUNT/$TOTAL_COUNT)"
else
  print_warning "Some Jitsi deployments may not be ready ($READY_COUNT/$TOTAL_COUNT), but continuing..."
fi

print_success "Jitsi Meet deployed successfully for $MT_ENV environment"
print_status "Namespace: $NS_JITSI"
print_status "Jitsi will be available at: https://${JITSI_HOST}"
print_status "Authentication: Keycloak SSO via ${AUTH_HOST}"
print_status "  - Moderators: Click 'I am the host' to login via Keycloak"
print_status "  - Guests: Can join existing meetings without login"
