#!/bin/bash

# Deploy Jitsi Meet using static Kubernetes manifests
# This script applies environment-specific Jitsi manifests using envsubst
#
# Namespace structure:
#   - Jitsi in NS_JITSI (tenant-prefixed namespace, e.g., 'tn-example-jitsi')

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Require MT_ENV and TENANT
MT_ENV=${MT_ENV:-prod}
REPO_ROOT="${REPO_ROOT:-/workspace}"

# Parse nesting level for deploy notifications
NESTING_LEVEL=0
for arg in "$@"; do
  case "$arg" in
    --nesting-level=*) NESTING_LEVEL="${arg#*=}" ;;
  esac
done
_MT_NOTIFY_NESTING_LEVEL=$NESTING_LEVEL

source "${REPO_ROOT}/scripts/lib/notify.sh"
mt_deploy_start "deploy-jitsi"

if [ -z "${MT_ENV:-}" ]; then
    print_error "MT_ENV is not set. Usage: MT_ENV=dev TENANT=example ./apps/deploy-jitsi.sh"
    exit 1
fi

if [ -z "${TENANT:-}" ]; then
    print_error "TENANT is not set. Usage: MT_ENV=dev TENANT=example ./apps/deploy-jitsi.sh"
    exit 1
fi

export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/kubeconfig.$MT_ENV.yaml}"

# Namespace configuration
NS_JITSI="${NS_JITSI:-tn-${TENANT}-jitsi}"

# Tenant configuration
TENANT_DIR="$REPO_ROOT/tenants/$TENANT"
TENANT_CONFIG="$TENANT_DIR/$MT_ENV.config.yaml"

if [ ! -f "$TENANT_CONFIG" ]; then
    print_error "Tenant config not found: $TENANT_CONFIG"
    exit 1
fi

print_status "Deploying Jitsi Meet for environment: $MT_ENV"
print_status "Tenant: $TENANT"
print_status "Jitsi namespace: $NS_JITSI"

# Validate required environment variables (set by create_env from tenant config)
# These must be exported before running this script
required_vars=("JITSI_HOST" "AUTH_HOST" "MATRIX_HOST" "DOCS_HOST")
missing_vars=()
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -gt 0 ]; then
    print_error "Required environment variables not set: ${missing_vars[*]}"
    print_error "This script should be called from create_env which sets these from tenant config."
    print_error "Or set them manually: JITSI_HOST=jitsi.example.org AUTH_HOST=auth.example.org ..."
    exit 1
fi
print_status "Using environment: JITSI_HOST=$JITSI_HOST, AUTH_HOST=$AUTH_HOST"

# Load secrets (for JWT_APP_SECRET)
# When called from create_env, tenant-specific secrets are already exported.
# Only source the shared secrets file as a fallback for standalone runs,
# to avoid overwriting tenant-specific values with another tenant's secrets.
if [ -z "${TF_VAR_jitsi_jwt_app_secret:-}" ]; then
    if [ -f "$REPO_ROOT/secrets.${MT_ENV}.tfvars.env" ]; then
        source "$REPO_ROOT/secrets.${MT_ENV}.tfvars.env"
        print_status "Loaded secrets from secrets.${MT_ENV}.tfvars.env"
    else
        print_error "Secrets file secrets.${MT_ENV}.tfvars.env not found."
        exit 1
    fi
else
    print_status "Using secrets from environment (set by create_env)"
fi

# Validate required secrets
if [ -z "${TF_VAR_jitsi_jwt_app_secret:-}" ]; then
    print_error "TF_VAR_jitsi_jwt_app_secret not set in secrets.${MT_ENV}.tfvars.env"
    print_error "Generate one with: openssl rand -hex 32"
    exit 1
fi
export JWT_APP_SECRET="${TF_VAR_jitsi_jwt_app_secret}"

# Export TURN shared secret for prosody.yaml.tpl envsubst
# Prefer TURN_SHARED_SECRET if already set by create_env, fallback to TF_VAR_turn_shared_secret
if [ -z "${TURN_SHARED_SECRET:-}" ] && [ -n "${TF_VAR_turn_shared_secret:-}" ]; then
    export TURN_SHARED_SECRET="${TF_VAR_turn_shared_secret}"
fi
if [ -z "${TURN_SHARED_SECRET:-}" ]; then
    print_error "TURN_SHARED_SECRET not set. Set it in tenant secrets (turn.shared_secret) or secrets.${MT_ENV}.tfvars.env (TF_VAR_turn_shared_secret)."
    exit 1
fi

# Get TURN server IP from phase1 outputs (if available)
if [ -f "$REPO_ROOT/phase1/terraform.tfstate.d/${MT_ENV}/terraform.tfstate" ]; then
    TURN_SERVER_IP=$(cd "$REPO_ROOT/phase1" && terraform output -raw turn_server_ip 2>/dev/null || echo "")
    if [ -n "$TURN_SERVER_IP" ] && [ "$TURN_SERVER_IP" != "null" ]; then
        export TURN_SERVER_IP
        print_status "TURN server IP: $TURN_SERVER_IP"
    else
        print_error "TURN server IP not available. Ensure phase1 has been applied."
        exit 1
    fi
else
    print_error "Terraform state not found. Ensure phase1 has been applied."
    exit 1
fi

# Get JVB port from tenant config (unique per tenant for multi-tenancy)
JVB_PORT=$(yq '.resources.jitsi.jvb_port' "$TENANT_CONFIG")
if [ -z "$JVB_PORT" ] || [ "$JVB_PORT" = "null" ]; then
    print_error "jvb_port not configured in $TENANT_CONFIG"
    print_error "Add 'resources.jitsi.jvb_port: <port>' to the tenant config (e.g., 31000)"
    exit 1
fi
export JVB_PORT
print_status "JVB port: $JVB_PORT (hostPort for UDP media, IP discovered dynamically via Downward API)"

# Load replica counts from tenant config (needed for Deployment replicas and HPAs)
export JITSI_WEB_MIN_REPLICAS=$(yq '.resources.jitsi.web.min_replicas // 1' "$TENANT_CONFIG")
export JITSI_WEB_MAX_REPLICAS=$(yq '.resources.jitsi.web.max_replicas // 3' "$TENANT_CONFIG")
export JVB_MIN_REPLICAS=$(yq '.resources.jitsi.jvb.min_replicas // 1' "$TENANT_CONFIG")
export JVB_MAX_REPLICAS=$(yq '.resources.jitsi.jvb.max_replicas // 3' "$TENANT_CONFIG")

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
    --dry-run=client -o yaml | kubectl apply -f -
print_success "jitsi-secrets created/updated with strong passwords and JWT_APP_SECRET"

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
# Force StatefulSet rollout restart to ensure pods pick up spec changes
# (StatefulSets with CrashLoopBackOff pods may not auto-restart on apply)
kubectl rollout restart statefulset/jitsi-prosody -n "$NS_JITSI"
# Delete existing pod if stuck in CrashLoopBackOff so the controller creates a new one
if kubectl get pod jitsi-prosody-0 -n "$NS_JITSI" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null | grep -q "CrashLoopBackOff"; then
    print_warning "Prosody pod stuck in CrashLoopBackOff — deleting to force recreation with new spec"
    kubectl delete pod jitsi-prosody-0 -n "$NS_JITSI" --grace-period=0 --force 2>/dev/null || true
fi
# JVB uses specific variable substitution to preserve shell variables in init container scripts
envsubst '${JVB_PORT} ${JITSI_HOST} ${TURN_SERVER_IP} ${JVB_MIN_REPLICAS}' < "$REPO_ROOT/apps/manifests/jitsi/jvb.yaml.tpl" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -
envsubst < "$REPO_ROOT/apps/manifests/jitsi/jicofo.yaml.tpl" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -

# Apply templated ConfigMap
envsubst < "$REPO_ROOT/apps/manifests/jitsi/web-config.yaml.tpl" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -

# Apply templated Ingress
envsubst < "$REPO_ROOT/apps/manifests/jitsi/ingress.yaml.tpl" | sed "s/namespace: matrix/namespace: $NS_JITSI/g" | kubectl apply -f -

# Deploy HorizontalPodAutoscalers (HPA) for auto-scaling
print_status "Deploying HPAs for Jitsi web and JVB..."
envsubst < "$REPO_ROOT/apps/manifests/jitsi/web-hpa.yaml.tpl" | kubectl apply -f -
envsubst < "$REPO_ROOT/apps/manifests/jitsi/jvb-hpa.yaml.tpl" | kubectl apply -f -
print_success "Jitsi HPAs deployed (CPU 80% threshold)"

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
