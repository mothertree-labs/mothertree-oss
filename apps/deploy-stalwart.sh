#!/bin/bash

# Deploy Stalwart Mail Server using static Kubernetes manifests
# This script applies environment-specific Stalwart manifests using envsubst
#
# Namespace structure:
#   - Stalwart in NS_MAIL (tenant-prefixed namespace, e.g., 'tn-example-mail')
#
# Prerequisites:
#   - PostgreSQL database created in infra-db namespace
#   - S3 bucket created for mail storage
#   - Keycloak OIDC client configured

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
mt_deploy_start "deploy-stalwart"

if [ -z "${MT_ENV:-}" ]; then
    print_error "MT_ENV is not set. Usage: MT_ENV=dev TENANT=example ./apps/deploy-stalwart.sh"
    exit 1
fi

if [ -z "${TENANT:-}" ]; then
    print_error "TENANT is not set. Usage: MT_ENV=dev TENANT=example ./apps/deploy-stalwart.sh"
    exit 1
fi

export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/kubeconfig.$MT_ENV.yaml}"

# Namespace configuration - always derive from TENANT to avoid conflicts
# NOTE: Must be exported for envsubst to substitute in templates
export NS_MAIL="tn-${TENANT}-mail"
export NS_INGRESS="${NS_INGRESS:-infra-ingress}"

# Tenant configuration
TENANT_DIR="$REPO_ROOT/tenants/$TENANT"
TENANT_CONFIG="$TENANT_DIR/$MT_ENV.config.yaml"
TENANT_SECRETS="$TENANT_DIR/$MT_ENV.secrets.yaml"

if [ ! -f "$TENANT_CONFIG" ]; then
    print_error "Tenant config not found: $TENANT_CONFIG"
    exit 1
fi

if [ ! -f "$TENANT_SECRETS" ]; then
    print_error "Tenant secrets not found: $TENANT_SECRETS"
    exit 1
fi

print_status "Deploying Stalwart Mail Server for environment: $MT_ENV"
print_status "Tenant: $TENANT"
print_status "Mail namespace: $NS_MAIL"

# Check if mail_enabled feature flag is set
MAIL_ENABLED=$(yq '.features.mail_enabled // false' "$TENANT_CONFIG")
if [ "$MAIL_ENABLED" != "true" ]; then
    print_warning "Mail not enabled for tenant $TENANT (features.mail_enabled is not true)"
    print_warning "Skipping Stalwart deployment"
    exit 0
fi

# Load configuration from tenant config
export TENANT_NAME="$TENANT"
export TENANT_DOMAIN=$(yq '.dns.domain' "$TENANT_CONFIG")
export MAIL_SUBDOMAIN=$(yq '.dns.mail_subdomain' "$TENANT_CONFIG")
export ENV_DNS_LABEL=$(yq '.dns.env_dns_label // ""' "$TENANT_CONFIG")
export KEYCLOAK_REALM=$(yq '.keycloak.realm' "$TENANT_CONFIG")
export S3_MAIL_BUCKET=$(yq '.s3.mail_bucket' "$TENANT_CONFIG")
export S3_CLUSTER=$(yq '.s3.cluster' "$TENANT_CONFIG")
export STALWART_DB_NAME=$(yq '.database.stalwart_db' "$TENANT_CONFIG")
export STALWART_DB_USER="stalwart_${TENANT}"

# Validate database config
if [ -z "$STALWART_DB_NAME" ] || [ "$STALWART_DB_NAME" = "null" ]; then
    print_error "STALWART_DB_NAME not set. Add 'database.stalwart_db' to $TENANT_CONFIG"
    exit 1
fi
print_status "Database: $STALWART_DB_NAME (user: $STALWART_DB_USER)"

# Derive PG_HOST if not passed in from the environment
NS_DB="${NS_DB:-infra-db}"
if [ -z "${PG_HOST:-}" ]; then
    if kubectl get service docs-postgresql-primary -n "$NS_DB" >/dev/null 2>&1; then
        export PG_HOST="docs-postgresql-primary.${NS_DB}.svc.cluster.local"
        print_status "PostgreSQL: detected replication mode (docs-postgresql-primary)"
    elif kubectl get service docs-postgresql -n "$NS_DB" >/dev/null 2>&1; then
        export PG_HOST="docs-postgresql.${NS_DB}.svc.cluster.local"
        print_status "PostgreSQL: detected standalone mode (docs-postgresql)"
    else
        print_error "PostgreSQL not found in $NS_DB namespace and PG_HOST not set."
        print_error "Either set PG_HOST or run 'deploy_infra $MT_ENV' first."
        exit 1
    fi
else
    print_status "Using PG_HOST from environment: $PG_HOST"
fi

# Resource configuration
export STALWART_MEMORY_REQUEST=$(yq '.resources.stalwart.memory_request // "256Mi"' "$TENANT_CONFIG")
export STALWART_MEMORY_LIMIT=$(yq '.resources.stalwart.memory_limit // "1Gi"' "$TENANT_CONFIG")
export STALWART_CPU_REQUEST=$(yq '.resources.stalwart.cpu_request // "100m"' "$TENANT_CONFIG")
export STALWART_CPU_LIMIT=$(yq '.resources.stalwart.cpu_limit // "500m"' "$TENANT_CONFIG")
export STALWART_STORAGE_SIZE=$(yq '.resources.stalwart.storage_size // "1Gi"' "$TENANT_CONFIG")
export STALWART_MIN_REPLICAS=$(yq '.resources.stalwart.min_replicas // 1' "$TENANT_CONFIG")
export STALWART_MAX_REPLICAS=$(yq '.resources.stalwart.max_replicas // 5' "$TENANT_CONFIG")

# Multi-tenant mail ports (unique per tenant, like jvb_port pattern)
export STALWART_SMTPS_PORT=$(yq '.resources.stalwart.smtps_port' "$TENANT_CONFIG")
export STALWART_SUBMISSION_PORT=$(yq '.resources.stalwart.submission_port' "$TENANT_CONFIG")
export STALWART_IMAPS_PORT=$(yq '.resources.stalwart.imaps_port' "$TENANT_CONFIG")

# App password ports (PLAIN/LOGIN via internal directory - for iOS Mail, Thunderbird)
export STALWART_IMAPS_APP_PORT=$(yq '.resources.stalwart.imaps_app_port' "$TENANT_CONFIG")
export STALWART_SUBMISSION_APP_PORT=$(yq '.resources.stalwart.submission_app_port' "$TENANT_CONFIG")

# Validate mail ports are configured
if [ -z "$STALWART_SMTPS_PORT" ] || [ "$STALWART_SMTPS_PORT" = "null" ]; then
    print_error "STALWART_SMTPS_PORT not configured. Add 'resources.stalwart.smtps_port' to $TENANT_CONFIG"
    exit 1
fi
if [ -z "$STALWART_SUBMISSION_PORT" ] || [ "$STALWART_SUBMISSION_PORT" = "null" ]; then
    print_error "STALWART_SUBMISSION_PORT not configured. Add 'resources.stalwart.submission_port' to $TENANT_CONFIG"
    exit 1
fi
if [ -z "$STALWART_IMAPS_PORT" ] || [ "$STALWART_IMAPS_PORT" = "null" ]; then
    print_error "STALWART_IMAPS_PORT not configured. Add 'resources.stalwart.imaps_port' to $TENANT_CONFIG"
    exit 1
fi
if [ -z "$STALWART_IMAPS_APP_PORT" ] || [ "$STALWART_IMAPS_APP_PORT" = "null" ]; then
    print_error "STALWART_IMAPS_APP_PORT not configured. Add 'resources.stalwart.imaps_app_port' to $TENANT_CONFIG"
    exit 1
fi
if [ -z "$STALWART_SUBMISSION_APP_PORT" ] || [ "$STALWART_SUBMISSION_APP_PORT" = "null" ]; then
    print_error "STALWART_SUBMISSION_APP_PORT not configured. Add 'resources.stalwart.submission_app_port' to $TENANT_CONFIG"
    exit 1
fi
print_status "Mail ports: SMTPS=${STALWART_SMTPS_PORT}, Submission=${STALWART_SUBMISSION_PORT}, IMAPS=${STALWART_IMAPS_PORT}"
print_status "App password ports: IMAPS=${STALWART_IMAPS_APP_PORT}, Submission=${STALWART_SUBMISSION_APP_PORT}"

# Build full hostnames
if [ -n "$ENV_DNS_LABEL" ] && [ "$ENV_DNS_LABEL" != "null" ]; then
    export MAIL_HOST="${MAIL_SUBDOMAIN}.${ENV_DNS_LABEL}.${TENANT_DOMAIN}"
    export IMAP_HOST="imap.${ENV_DNS_LABEL}.${TENANT_DOMAIN}"
    export SMTP_HOST="smtp.${ENV_DNS_LABEL}.${TENANT_DOMAIN}"
    export AUTH_HOST="auth.${ENV_DNS_LABEL}.${TENANT_DOMAIN}"
    # Admin UI follows the internal subdomain pattern (tenant-specific)
    export WEBADMIN_HOST="webadmin.internal.${ENV_DNS_LABEL}.${TENANT_DOMAIN}"
else
    export MAIL_HOST="${MAIL_SUBDOMAIN}.${TENANT_DOMAIN}"
    export IMAP_HOST="imap.${TENANT_DOMAIN}"
    export SMTP_HOST="smtp.${TENANT_DOMAIN}"
    export AUTH_HOST="auth.${TENANT_DOMAIN}"
    # Admin UI for prod (tenant-specific)
    export WEBADMIN_HOST="webadmin.prod.${TENANT_DOMAIN}"
fi

# Email domain for inbound mail routing (e.g., dev.example.com for dev, example.com for prod)
# Read from config's smtp.domain, fallback to computed value based on env_dns_label
SMTP_DOMAIN_CONFIG=$(yq '.smtp.domain // ""' "$TENANT_CONFIG")
if [ -n "$SMTP_DOMAIN_CONFIG" ] && [ "$SMTP_DOMAIN_CONFIG" != "null" ]; then
    export EMAIL_DOMAIN="$SMTP_DOMAIN_CONFIG"
elif [ -n "$ENV_DNS_LABEL" ] && [ "$ENV_DNS_LABEL" != "null" ]; then
    export EMAIL_DOMAIN="${ENV_DNS_LABEL}.${TENANT_DOMAIN}"
else
    export EMAIL_DOMAIN="${TENANT_DOMAIN}"
fi

print_status "Mail host: $MAIL_HOST"
print_status "Auth host: $AUTH_HOST"
print_status "Admin host: $WEBADMIN_HOST"
print_status "Email domain: $EMAIL_DOMAIN (for inbound mail routing)"

# Load secrets from tenant secrets file
export STALWART_ADMIN_PASSWORD=$(yq '.stalwart.admin_password' "$TENANT_SECRETS")
export STALWART_DB_PASSWORD=$(yq '.database.stalwart_password' "$TENANT_SECRETS")
export STALWART_OIDC_SECRET=$(yq '.oidc.stalwart_client_secret' "$TENANT_SECRETS")
export S3_MAIL_ACCESS_KEY=$(yq '.s3_mail.access_key' "$TENANT_SECRETS")
export S3_MAIL_SECRET_KEY=$(yq '.s3_mail.secret_key' "$TENANT_SECRETS")

# Validate required secrets
required_secrets=("STALWART_ADMIN_PASSWORD" "STALWART_DB_PASSWORD" "STALWART_OIDC_SECRET" "S3_MAIL_ACCESS_KEY" "S3_MAIL_SECRET_KEY")
missing_secrets=()
for secret in "${required_secrets[@]}"; do
    value="${!secret:-}"
    if [ -z "$value" ] || [ "$value" = "null" ] || [[ "$value" == *"PLACEHOLDER"* ]]; then
        missing_secrets+=("$secret")
    fi
done

if [ ${#missing_secrets[@]} -gt 0 ]; then
    print_error "Required secrets not set or are placeholders: ${missing_secrets[*]}"
    print_error "Update $TENANT_SECRETS with actual values"
    exit 1
fi

# Validate S3 bucket
if [ -z "$S3_MAIL_BUCKET" ] || [ "$S3_MAIL_BUCKET" = "null" ]; then
    print_error "S3 mail bucket not configured in $TENANT_CONFIG"
    print_error "Add 's3.mail_bucket' to the tenant config"
    exit 1
fi

# Generate config checksum for pod annotations
# Include both secrets AND the rendered config template to trigger restarts on any config change
RENDERED_CONFIG=$(envsubst < "$REPO_ROOT/apps/manifests/stalwart/stalwart.yaml.tpl" 2>/dev/null || echo "")
export CONFIG_CHECKSUM=$(echo -n "$STALWART_ADMIN_PASSWORD$STALWART_DB_PASSWORD$S3_MAIL_ACCESS_KEY$RENDERED_CONFIG" | sha256sum | cut -d' ' -f1 | head -c 12)
print_status "Config checksum: $CONFIG_CHECKSUM"

# Ensure namespace exists
print_status "Ensuring $NS_MAIL namespace exists..."
kubectl create namespace "$NS_MAIL" --dry-run=client -o yaml | kubectl apply -f -
print_success "Namespace ready: $NS_MAIL"

# =============================================================================
# Database Initialization
# =============================================================================
print_status "Initializing PostgreSQL database for Stalwart..."

# Copy the PostgreSQL admin secret from infra-db namespace
# This is needed for the db-init job to connect as postgres admin
print_status "Copying PostgreSQL admin secret to $NS_MAIL namespace..."

# Extract just the password data and create a clean secret (avoids metadata conflicts)
PG_PASSWORD=$(kubectl get secret docs-postgresql -n infra-db -o jsonpath='{.data.postgres-password}')
if [ -z "$PG_PASSWORD" ]; then
    print_error "Could not retrieve PostgreSQL admin password from infra-db namespace"
    exit 1
fi

kubectl create secret generic docs-postgresql \
    --namespace="$NS_MAIL" \
    --from-literal=postgres-password="$(echo "$PG_PASSWORD" | base64 -d)" \
    --dry-run=client -o yaml | kubectl apply -f -
print_success "PostgreSQL admin secret copied"

# Apply Stalwart secrets for db-init job
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: stalwart-secrets
  namespace: $NS_MAIL
type: Opaque
stringData:
  STALWART_ADMIN_PASSWORD: "$STALWART_ADMIN_PASSWORD"
  STALWART_DB_PASSWORD: "$STALWART_DB_PASSWORD"
  STALWART_OIDC_SECRET: "$STALWART_OIDC_SECRET"
  S3_ACCESS_KEY: "$S3_MAIL_ACCESS_KEY"
  S3_SECRET_KEY: "$S3_MAIL_SECRET_KEY"
EOF
print_success "Stalwart secrets applied"

# Delete any previous db-init job (jobs are not updated, they need to be recreated)
print_status "Deleting any existing db-init job in $NS_MAIL..."
if kubectl get job stalwart-db-init -n "$NS_MAIL" >/dev/null 2>&1; then
    kubectl delete job stalwart-db-init -n "$NS_MAIL" --force --grace-period=0 2>/dev/null || true
    # Also delete any orphaned pods from previous job runs
    kubectl delete pods -n "$NS_MAIL" -l job-name=stalwart-db-init --force --grace-period=0 2>/dev/null || true
    # Wait until job is fully deleted (avoid race condition)
    print_status "Waiting for job deletion to complete..."
    for i in $(seq 1 60); do
        if ! kubectl get job stalwart-db-init -n "$NS_MAIL" >/dev/null 2>&1; then
            print_status "Job deleted"
            break
        fi
        if [ $i -eq 60 ]; then
            print_error "Timeout waiting for job deletion. Please manually delete: kubectl delete job stalwart-db-init -n $NS_MAIL --force --grace-period=0"
            exit 1
        fi
        sleep 1
    done
fi

# Create the database initialization job
# Note: Jobs are immutable, so we use 'create' instead of 'apply'
print_status "Running database initialization job..."
print_status "DB_NAME=$STALWART_DB_NAME, DB_USER=$STALWART_DB_USER"

# Use explicit variable list for envsubst to ensure all variables are substituted
envsubst '${NS_MAIL} ${STALWART_DB_NAME} ${STALWART_DB_USER} ${PG_HOST}' \
    < "$REPO_ROOT/apps/manifests/stalwart/db-init-job.yaml.tpl" | kubectl create -f -

# Wait for the job to complete
print_status "Waiting for database initialization to complete..."
if kubectl wait --for=condition=complete job/stalwart-db-init -n "$NS_MAIL" --timeout=120s 2>/dev/null; then
    print_success "Database initialization completed successfully"
else
    # Check if job failed
    JOB_STATUS=$(kubectl get job stalwart-db-init -n "$NS_MAIL" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
    if [ "$JOB_STATUS" = "True" ]; then
        print_error "Database initialization job failed"
        print_status "Job logs:"
        kubectl logs -n "$NS_MAIL" job/stalwart-db-init || true
        exit 1
    else
        print_warning "Database initialization may not have completed (timeout)"
        print_status "Check job status: kubectl get job stalwart-db-init -n $NS_MAIL"
    fi
fi

# Apply Stalwart manifests
print_status "Applying Stalwart manifests..."

# Apply main Stalwart manifest (Secret, ConfigMap, Deployment, Service)
envsubst < "$REPO_ROOT/apps/manifests/stalwart/stalwart.yaml.tpl" | kubectl apply -f -
print_success "Stalwart Deployment and Service applied"

# Deploy HorizontalPodAutoscaler (HPA) for auto-scaling
print_status "Deploying HPA for Stalwart..."
envsubst < "$REPO_ROOT/apps/manifests/stalwart/stalwart-hpa.yaml.tpl" | kubectl apply -f -
print_success "Stalwart HPA deployed (CPU 80% threshold)"

# Apply Certificate for TLS
envsubst < "$REPO_ROOT/apps/manifests/stalwart/certificate.yaml.tpl" | kubectl apply -f -
print_success "TLS Certificate requested"

# Apply public ingress for webmail
# Note: nginx ingress controller may reject apply if host/path already exists, so we handle that gracefully
if kubectl get ingress stalwart-webmail -n "$NS_MAIL" >/dev/null 2>&1; then
    print_status "Public ingress already exists for $MAIL_HOST (skipping)"
else
    envsubst < "$REPO_ROOT/apps/manifests/stalwart/ingress.yaml.tpl" | kubectl apply -f -
    print_success "Public ingress applied for $MAIL_HOST"
fi

# Apply internal ingress for admin UI
if kubectl get ingress stalwart-webadmin -n "$NS_MAIL" >/dev/null 2>&1; then
    print_status "Internal ingress already exists for $WEBADMIN_HOST (skipping)"
else
    envsubst < "$REPO_ROOT/apps/manifests/stalwart/ingress-internal.yaml.tpl" | kubectl apply -f -
    print_success "Internal ingress applied for $WEBADMIN_HOST"
fi

# =============================================================================
# Register tenant with Postfix for inbound mail routing
# =============================================================================
# Multi-tenant mail routing: Postfix receives inbound mail on port 25 and routes
# to the correct tenant's Stalwart based on recipient domain using transport_maps.
#
# Uses shared configure-mail-routing script that scans ALL tenants to ensure
# consistent configuration whether running create_env or deploy_infra.

print_status "Configuring Postfix inbound mail routing for all tenants..."

# Call shared mail routing configuration script
# This scans all tenants and rebuilds the complete routing config
if [ -x "$REPO_ROOT/scripts/configure-mail-routing" ]; then
    "$REPO_ROOT/scripts/configure-mail-routing" "$MT_ENV" --nesting-level=$((NESTING_LEVEL+1)) 2>&1 | while read line; do
        echo "  $line"
    done
    print_success "Postfix mail routing configured"
else
    print_warning "configure-mail-routing script not found - skipping routing config"
fi

# =============================================================================
# Configure nginx TCP proxy for tenant mail ports
# =============================================================================
# nginx-ingress proxies TCP connections from unique external ports to Stalwart's
# ClusterIP service on standard internal ports. Two things are needed:
# 1. tcp-services ConfigMap entries (tells nginx where to proxy)
# 2. LB service ports (tells the cloud LB to forward to nginx's NodePort)

print_status "Configuring nginx TCP proxy for tenant mail ports..."

# Create tcp-services ConfigMap if it doesn't exist
if ! kubectl get configmap tcp-services -n "$NS_INGRESS" >/dev/null 2>&1; then
    print_status "Creating tcp-services ConfigMap..."
    kubectl create configmap tcp-services -n "$NS_INGRESS"
fi

# Patch tcp-services ConfigMap with this tenant's port mappings
# Each entry maps an external port to namespace/service:internal-port
# Using strategic merge patch so other tenants' entries are preserved
print_status "Updating tcp-services ConfigMap for tenant $TENANT..."
kubectl patch configmap tcp-services -n "$NS_INGRESS" --type merge -p "$(cat <<EOF
{"data": {
  "${STALWART_SMTPS_PORT}": "${NS_MAIL}/stalwart:465",
  "${STALWART_SUBMISSION_PORT}": "${NS_MAIL}/stalwart:587",
  "${STALWART_IMAPS_PORT}": "${NS_MAIL}/stalwart:993",
  "${STALWART_IMAPS_APP_PORT}": "${NS_MAIL}/stalwart:994",
  "${STALWART_SUBMISSION_APP_PORT}": "${NS_MAIL}/stalwart:588"
}}
EOF
)"
print_success "tcp-services ConfigMap updated"

# Add ports to LB service (so cloud LB forwards them to nginx's NodePort)
print_status "Ensuring LB service has tenant mail ports..."
EXISTING_PORTS=$(kubectl get svc ingress-nginx-controller -n "$NS_INGRESS" -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || echo "")

for port_info in "smtps-${TENANT}:${STALWART_SMTPS_PORT}" "submission-${TENANT}:${STALWART_SUBMISSION_PORT}" "imaps-${TENANT}:${STALWART_IMAPS_PORT}" "imaps-app-${TENANT}:${STALWART_IMAPS_APP_PORT}" "sub-app-${TENANT}:${STALWART_SUBMISSION_APP_PORT}"; do
    port_name="${port_info%%:*}"
    port_num="${port_info##*:}"
    if ! echo "$EXISTING_PORTS" | grep -qw "$port_num"; then
        print_status "Adding port $port_name ($port_num) to LB..."
        kubectl patch svc ingress-nginx-controller -n "$NS_INGRESS" --type='json' \
            -p='[{"op": "add", "path": "/spec/ports/-", "value": {"name": "'"$port_name"'", "port": '"$port_num"', "targetPort": '"$port_num"', "protocol": "TCP"}}]'
    else
        print_status "Port $port_num already on LB"
    fi
done
print_success "Tenant mail ports configured on LB and nginx TCP proxy"

# Wait for Deployment to be ready
print_status "Waiting for Stalwart Deployment to be ready..."
if kubectl rollout status deployment/stalwart -n "$NS_MAIL" --timeout=300s; then
    print_success "Stalwart Deployment is ready"
else
    print_warning "Stalwart StatefulSet may not be fully ready"
    print_status "Check logs with: kubectl logs -n $NS_MAIL -l app=stalwart"
fi

# =============================================================================
# Register local domain in Stalwart
# =============================================================================
# Domain principals tell Stalwart which domains are local. Without this,
# Stalwart treats all domains as external and recipient validation fails.
# This is essential for is_local_domain() to work correctly.
print_status "Registering local domain $EMAIL_DOMAIN in Stalwart..."

# Use port-forward to call the API (Stalwart container doesn't have curl)
# API is on port 8080 (health listener, no TLS required)
LOCAL_PORT=$((RANDOM + 10000))
kubectl port-forward -n "$NS_MAIL" deployment/stalwart ${LOCAL_PORT}:8080 &>/dev/null &
PF_PID=$!
sleep 3

# Verify port-forward is working
if ! kill -0 $PF_PID 2>/dev/null; then
    print_error "Port-forward to Stalwart failed"
    print_error "Check if Stalwart pod is running: kubectl get pods -n $NS_MAIL"
    exit 1
fi

DOMAIN_RESULT=$(curl -s -w "\n%{http_code}" --max-time 10 -X POST "http://localhost:${LOCAL_PORT}/api/principal" \
    -u "admin:${STALWART_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d '{"type": "domain", "name": "'"${EMAIL_DOMAIN}"'", "description": "Local email domain for '"${TENANT}"'"}' 2>/dev/null)

kill $PF_PID 2>/dev/null || true

HTTP_CODE=$(echo "$DOMAIN_RESULT" | tail -n1)
RESPONSE_BODY=$(echo "$DOMAIN_RESULT" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    if echo "$RESPONSE_BODY" | grep -q '"data"'; then
        print_success "Domain $EMAIL_DOMAIN registered (id: $(echo "$RESPONSE_BODY" | jq -r '.data // "N/A"'))"
    elif echo "$RESPONSE_BODY" | grep -q "fieldAlreadyExists"; then
        print_status "Domain $EMAIL_DOMAIN already registered"
    else
        print_success "Domain $EMAIL_DOMAIN registration response: $RESPONSE_BODY"
    fi
elif [ -z "$HTTP_CODE" ]; then
    print_error "Domain registration failed: no response from Stalwart API"
    print_error "Check if Stalwart is running: kubectl get pods -n $NS_MAIL"
    exit 1
else
    print_error "Domain registration failed with HTTP $HTTP_CODE: $RESPONSE_BODY"
    print_error "This is required for inbound mail to work correctly"
    exit 1
fi

# Wait for TLS certificate
print_status "Checking TLS certificate status..."
CERT_TIMEOUT=120
for i in $(seq 1 $((CERT_TIMEOUT / 5))); do
    CERT_STATUS=$(kubectl get certificate stalwart-tls -n "$NS_MAIL" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$CERT_STATUS" = "True" ]; then
        print_success "TLS certificate is ready"
        break
    fi
    if [ $i -eq $((CERT_TIMEOUT / 5)) ]; then
        print_warning "TLS certificate may not be ready yet (timeout after ${CERT_TIMEOUT}s)"
        print_status "Check status with: kubectl get certificate -n $NS_MAIL"
    fi
    sleep 5
done

print_success "Stalwart Mail Server deployed successfully for $MT_ENV environment"
echo ""
print_status "Namespace: $NS_MAIL"
print_status "Webmail URL: https://${MAIL_HOST}"
print_status "Admin URL: https://${WEBADMIN_HOST} (VPN only)"
echo ""
print_status "Mail client configuration (unique ports for multi-tenant):"
print_status "  IMAP (OAUTHBEARER): ${MAIL_HOST}:${STALWART_IMAPS_PORT} (IMAPS with TLS)"
print_status "  IMAP (App Password): ${MAIL_HOST}:${STALWART_IMAPS_APP_PORT} (IMAPS with TLS)"
print_status "  SMTP (OAUTHBEARER): ${MAIL_HOST}:${STALWART_SUBMISSION_PORT} (STARTTLS) or :${STALWART_SMTPS_PORT} (TLS)"
print_status "  SMTP (App Password): ${MAIL_HOST}:${STALWART_SUBMISSION_APP_PORT} (STARTTLS)"
print_status "  Authentication: Keycloak SSO via ${AUTH_HOST}/realms/${KEYCLOAK_REALM}"
echo ""
print_status "Inbound mail (port 25) for @${EMAIL_DOMAIN} is routed via shared Postfix."
print_status "DNS SRV records for autodiscovery are created by create_env script."
echo ""
print_status "To check status: kubectl get pods -n $NS_MAIL"
print_status "To view logs: kubectl logs -n $NS_MAIL -l app=stalwart -f"
