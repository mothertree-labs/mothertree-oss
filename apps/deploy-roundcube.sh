#!/bin/bash

# Deploy Roundcube Webmail using static Kubernetes manifests
# This script applies environment-specific Roundcube manifests using envsubst
#
# Namespace structure:
#   - Roundcube in NS_WEBMAIL (tenant-prefixed namespace, e.g., 'tn-example-webmail')
#
# Prerequisites:
#   - Stalwart Mail Server deployed and accessible
#   - Keycloak OIDC client configured for Roundcube

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
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Parse nesting level for deploy notifications
NESTING_LEVEL=0
for arg in "$@"; do
  case "$arg" in
    --nesting-level=*) NESTING_LEVEL="${arg#*=}" ;;
  esac
done
_MT_NOTIFY_NESTING_LEVEL=$NESTING_LEVEL

source "${REPO_ROOT}/scripts/lib/notify.sh"
[[ -f "$REPO_ROOT/project.conf" ]] && source "$REPO_ROOT/project.conf"
mt_deploy_start "deploy-roundcube"

if [ -z "${MT_ENV:-}" ]; then
    print_error "MT_ENV is not set. Usage: MT_ENV=dev TENANT=example ./apps/deploy-roundcube.sh"
    exit 1
fi

if [ -z "${TENANT:-}" ]; then
    print_error "TENANT is not set. Usage: MT_ENV=dev TENANT=example ./apps/deploy-roundcube.sh"
    exit 1
fi

export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/kubeconfig.$MT_ENV.yaml}"

# Namespace configuration
export NS_WEBMAIL="${NS_WEBMAIL:-tn-${TENANT}-webmail}"
# Always derive from TENANT to avoid conflicts with inherited environment
export NS_MAIL="tn-${TENANT}-mail"

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

print_status "Deploying Roundcube Webmail for environment: $MT_ENV"
print_status "Tenant: $TENANT"
print_status "Webmail namespace: $NS_WEBMAIL"
print_status "Mail namespace: $NS_MAIL"

# Check if webmail_enabled feature flag is set
WEBMAIL_ENABLED=$(yq '.features.webmail_enabled // false' "$TENANT_CONFIG")
if [ "$WEBMAIL_ENABLED" != "true" ]; then
    print_warning "Webmail not enabled for tenant $TENANT (features.webmail_enabled is not true)"
    print_warning "Skipping Roundcube deployment"
    exit 0
fi

# Check if mail is enabled (required for webmail)
MAIL_ENABLED=$(yq '.features.mail_enabled // false' "$TENANT_CONFIG")
if [ "$MAIL_ENABLED" != "true" ]; then
    print_error "Mail is not enabled for tenant $TENANT but webmail is."
    print_error "Enable 'features.mail_enabled' in tenant config first."
    exit 1
fi

# Load configuration from tenant config
export TENANT_NAME="$TENANT"
export TENANT_DOMAIN=$(yq '.dns.domain' "$TENANT_CONFIG")
export TENANT_DISPLAY_NAME=$(yq '.tenant.display_name' "$TENANT_CONFIG")
export WEBMAIL_SUBDOMAIN=$(yq '.dns.webmail_subdomain' "$TENANT_CONFIG")
export MAIL_SUBDOMAIN=$(yq '.dns.mail_subdomain' "$TENANT_CONFIG")
export FILES_SUBDOMAIN=$(yq '.dns.files_subdomain' "$TENANT_CONFIG")
export ENV_DNS_LABEL=$(yq '.dns.env_dns_label // ""' "$TENANT_CONFIG")
export KEYCLOAK_REALM=$(yq '.keycloak.realm' "$TENANT_CONFIG")

# Database configuration
export ROUNDCUBE_DB_NAME=$(yq '.database.roundcube_db' "$TENANT_CONFIG")
export ROUNDCUBE_DB_USER="roundcube_${TENANT}"

# Validate database config
if [ -z "$ROUNDCUBE_DB_NAME" ] || [ "$ROUNDCUBE_DB_NAME" = "null" ]; then
    print_error "ROUNDCUBE_DB_NAME not set. Add 'database.roundcube_db' to $TENANT_CONFIG"
    exit 1
fi
print_status "Database: $ROUNDCUBE_DB_NAME (user: $ROUNDCUBE_DB_USER)"

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
export ROUNDCUBE_MEMORY_REQUEST=$(yq '.resources.roundcube.memory_request // "128Mi"' "$TENANT_CONFIG")
export ROUNDCUBE_MEMORY_LIMIT=$(yq '.resources.roundcube.memory_limit // "256Mi"' "$TENANT_CONFIG")
export ROUNDCUBE_CPU_REQUEST=$(yq '.resources.roundcube.cpu_request // "50m"' "$TENANT_CONFIG")
export ROUNDCUBE_CPU_LIMIT=$(yq '.resources.roundcube.cpu_limit // "200m"' "$TENANT_CONFIG")
export ROUNDCUBE_MIN_REPLICAS=$(yq '.resources.roundcube.min_replicas // 1' "$TENANT_CONFIG")
export ROUNDCUBE_MAX_REPLICAS=$(yq '.resources.roundcube.max_replicas // 3' "$TENANT_CONFIG")

# Build full hostnames
if [ -n "$ENV_DNS_LABEL" ] && [ "$ENV_DNS_LABEL" != "null" ]; then
    export WEBMAIL_HOST="${WEBMAIL_SUBDOMAIN}.${ENV_DNS_LABEL}.${TENANT_DOMAIN}"
    export MAIL_HOST="${MAIL_SUBDOMAIN}.${ENV_DNS_LABEL}.${TENANT_DOMAIN}"
    export FILES_HOST="${FILES_SUBDOMAIN}.${ENV_DNS_LABEL}.${TENANT_DOMAIN}"
    export AUTH_HOST="auth.${ENV_DNS_LABEL}.${TENANT_DOMAIN}"
else
    export WEBMAIL_HOST="${WEBMAIL_SUBDOMAIN}.${TENANT_DOMAIN}"
    export MAIL_HOST="${MAIL_SUBDOMAIN}.${TENANT_DOMAIN}"
    export FILES_HOST="${FILES_SUBDOMAIN}.${TENANT_DOMAIN}"
    export AUTH_HOST="auth.${TENANT_DOMAIN}"
fi

print_status "Webmail host: $WEBMAIL_HOST"
print_status "Mail host: $MAIL_HOST"
print_status "Files host (CalDAV): $FILES_HOST"
print_status "Auth host: $AUTH_HOST"

# Load secrets from tenant secrets file
export ROUNDCUBE_OIDC_SECRET=$(yq '.oidc.roundcube_client_secret' "$TENANT_SECRETS")
export ROUNDCUBE_DB_PASSWORD=$(yq '.database.roundcube_password' "$TENANT_SECRETS")

# Generate DES key for session encryption (24 characters from random data)
# This is deterministic based on tenant+env to avoid regenerating on each deploy
export ROUNDCUBE_DES_KEY=$(echo -n "${TENANT}${MT_ENV}roundcube" | sha256sum | cut -c1-24)

# Validate required secrets
required_secrets=("ROUNDCUBE_OIDC_SECRET" "ROUNDCUBE_DB_PASSWORD")
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

# Generate config checksum for pod annotations
# Include both secrets AND the rendered config template to trigger restarts on any config change
RENDERED_CONFIG=$(envsubst < "$REPO_ROOT/apps/manifests/roundcube/roundcube.yaml.tpl" 2>/dev/null || echo "")
export CONFIG_CHECKSUM=$(echo -n "$ROUNDCUBE_OIDC_SECRET$ROUNDCUBE_DES_KEY$RENDERED_CONFIG" | sha256sum | cut -d' ' -f1 | head -c 12)
print_status "Config checksum: $CONFIG_CHECKSUM"

# Ensure namespace exists
print_status "Ensuring $NS_WEBMAIL namespace exists..."
kubectl create namespace "$NS_WEBMAIL" --dry-run=client -o yaml | kubectl apply -f -
print_success "Namespace ready: $NS_WEBMAIL"

# =============================================================================
# Database Initialization
# =============================================================================
print_status "Initializing PostgreSQL database for Roundcube..."

# Copy the PostgreSQL admin secret from infra-db namespace
print_status "Copying PostgreSQL admin secret to $NS_WEBMAIL namespace..."
PG_PASSWORD=$(kubectl get secret docs-postgresql -n infra-db -o jsonpath='{.data.postgres-password}')
if [ -z "$PG_PASSWORD" ]; then
    print_error "Could not retrieve PostgreSQL admin password from infra-db namespace"
    exit 1
fi

kubectl create secret generic docs-postgresql \
    --namespace="$NS_WEBMAIL" \
    --from-literal=postgres-password="$(echo "$PG_PASSWORD" | base64 -d)" \
    --dry-run=client -o yaml | kubectl apply -f -
print_success "PostgreSQL admin secret copied"

# Apply Roundcube secrets first (needed by db-init job)
print_status "Applying Roundcube secrets..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: roundcube-secrets
  namespace: $NS_WEBMAIL
type: Opaque
stringData:
  ROUNDCUBE_OIDC_SECRET: "$ROUNDCUBE_OIDC_SECRET"
  ROUNDCUBE_DB_PASSWORD: "$ROUNDCUBE_DB_PASSWORD"
  ROUNDCUBEMAIL_DEFAULT_HOST: "ssl://stalwart.${NS_MAIL}.svc.cluster.local"
  ROUNDCUBEMAIL_SMTP_SERVER: "tls://stalwart.${NS_MAIL}.svc.cluster.local"
EOF
print_success "Roundcube secrets applied"

# Delete any previous db-init job
kubectl delete job roundcube-db-init -n "$NS_WEBMAIL" --ignore-not-found=true

# Apply the database initialization job
print_status "Running database initialization job..."
print_status "DB_NAME=$ROUNDCUBE_DB_NAME, DB_USER=$ROUNDCUBE_DB_USER"

envsubst '${NS_WEBMAIL} ${ROUNDCUBE_DB_NAME} ${ROUNDCUBE_DB_USER} ${PG_HOST}' \
    < "$REPO_ROOT/apps/manifests/roundcube/db-init-job.yaml.tpl" | kubectl apply -f -

# Wait for the job to complete
print_status "Waiting for database initialization to complete..."
if kubectl wait --for=condition=complete job/roundcube-db-init -n "$NS_WEBMAIL" --timeout=120s 2>/dev/null; then
    print_success "Database initialization completed successfully"
else
    JOB_STATUS=$(kubectl get job roundcube-db-init -n "$NS_WEBMAIL" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
    if [ "$JOB_STATUS" = "True" ]; then
        print_error "Database initialization job failed"
        print_status "Job logs:"
        kubectl logs -n "$NS_WEBMAIL" job/roundcube-db-init || true
        exit 1
    else
        print_warning "Database initialization may not have completed (timeout)"
        print_status "Check job status: kubectl get job roundcube-db-init -n $NS_WEBMAIL"
    fi
fi

# =============================================================================
# Apply Kolab/Calendar Plugin Database Schema
# =============================================================================
print_status "Applying Kolab/Calendar plugin database schema..."

# Get postgres admin password
PG_ADMIN_PASS=$(kubectl get secret docs-postgresql -n infra-db -o jsonpath='{.data.postgres-password}' | base64 -d)

# Determine PostgreSQL pod name based on architecture (replication vs standalone)
if [[ "$PG_HOST" == *"postgresql-primary"* ]]; then
    PG_POD_NAME="docs-postgresql-primary-0"
else
    PG_POD_NAME="docs-postgresql-0"
fi

# Check if kolab_folders table exists (indicates schema already applied)
KOLAB_EXISTS=$(kubectl exec -n infra-db "$PG_POD_NAME" -- bash -c "PGPASSWORD='$PG_ADMIN_PASS' psql -U postgres -d $ROUNDCUBE_DB_NAME -tAc \"SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'kolab_folders');\"" 2>/dev/null || echo "f")

if [ "$KOLAB_EXISTS" = "t" ]; then
    print_status "Kolab schema already exists, skipping"
else
    print_status "Applying libkolab schema..."
    cat "$REPO_ROOT/submodules/roundcubemail-plugins-kolab/plugins/libkolab/SQL/postgres.initial.sql" | \
        kubectl exec -i -n infra-db "$PG_POD_NAME" -- bash -c "PGPASSWORD='$PG_ADMIN_PASS' psql -U postgres -d $ROUNDCUBE_DB_NAME" >/dev/null
    print_success "libkolab schema applied"
    
    print_status "Applying caldav/calendar schema..."
    cat "$REPO_ROOT/submodules/roundcubemail-plugins-kolab/plugins/calendar/drivers/caldav/SQL/postgres.initial.sql" | \
        kubectl exec -i -n infra-db "$PG_POD_NAME" -- bash -c "PGPASSWORD='$PG_ADMIN_PASS' psql -U postgres -d $ROUNDCUBE_DB_NAME" >/dev/null
    print_success "caldav schema applied"
    
    # Grant permissions on new tables to the Roundcube user
    print_status "Granting permissions to $ROUNDCUBE_DB_USER..."
    kubectl exec -n infra-db "$PG_POD_NAME" -- bash -c "PGPASSWORD='$PG_ADMIN_PASS' psql -U postgres -d $ROUNDCUBE_DB_NAME -c \"GRANT ALL ON ALL TABLES IN SCHEMA public TO $ROUNDCUBE_DB_USER; GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO $ROUNDCUBE_DB_USER;\"" >/dev/null
    print_success "Permissions granted"
fi

# Apply Roundcube manifests
print_status "Applying Roundcube manifests..."

# Apply main Roundcube manifest (Secret, ConfigMap, Deployment, Service)
# Use explicit variable list to preserve PHP $config variables in the ConfigMap
export CONTAINER_REGISTRY="${CONTAINER_REGISTRY:-ghcr.io/YOUR_ORG}"
envsubst '${NS_WEBMAIL} ${NS_MAIL} ${AUTH_HOST} ${KEYCLOAK_REALM} ${ROUNDCUBE_DES_KEY} ${TENANT_DISPLAY_NAME} ${ROUNDCUBE_DB_USER} ${ROUNDCUBE_DB_NAME} ${TENANT_NAME} ${ROUNDCUBE_OIDC_SECRET} ${ROUNDCUBE_DB_PASSWORD} ${ROUNDCUBE_MEMORY_REQUEST} ${ROUNDCUBE_MEMORY_LIMIT} ${ROUNDCUBE_CPU_REQUEST} ${ROUNDCUBE_CPU_LIMIT} ${CONFIG_CHECKSUM} ${FILES_HOST} ${ROUNDCUBE_MIN_REPLICAS} ${PG_HOST} ${CONTAINER_REGISTRY}' \
    < "$REPO_ROOT/apps/manifests/roundcube/roundcube.yaml.tpl" | kubectl apply -f -
print_success "Roundcube Deployment and Service applied"

# Deploy HorizontalPodAutoscaler (HPA) for auto-scaling
print_status "Deploying HPA for Roundcube..."
envsubst < "$REPO_ROOT/apps/manifests/roundcube/roundcube-hpa.yaml.tpl" | kubectl apply -f -
print_success "Roundcube HPA deployed (CPU 80% threshold)"

# Apply Certificate for TLS
envsubst < "$REPO_ROOT/apps/manifests/roundcube/certificate.yaml.tpl" | kubectl apply -f -
print_success "TLS Certificate requested"

# Apply ingress for webmail
envsubst < "$REPO_ROOT/apps/manifests/roundcube/ingress.yaml.tpl" | kubectl apply -f -
print_success "Ingress applied for $WEBMAIL_HOST"

# Restart deployment to pick up config changes
print_status "Restarting Roundcube deployment to apply config changes..."
kubectl rollout restart deployment/roundcube -n "$NS_WEBMAIL"

# Wait for Deployment to be ready
print_status "Waiting for Roundcube Deployment to be ready..."
if kubectl rollout status deployment/roundcube -n "$NS_WEBMAIL" --timeout=180s; then
    print_success "Roundcube Deployment is ready"
else
    print_warning "Roundcube Deployment may not be fully ready"
    print_status "Check logs with: kubectl logs -n $NS_WEBMAIL -l app=roundcube"
fi

# Wait for TLS certificate
print_status "Checking TLS certificate status..."
CERT_TIMEOUT=120
for i in $(seq 1 $((CERT_TIMEOUT / 5))); do
    CERT_STATUS=$(kubectl get certificate roundcube-tls -n "$NS_WEBMAIL" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$CERT_STATUS" = "True" ]; then
        print_success "TLS certificate is ready"
        break
    fi
    if [ $i -eq $((CERT_TIMEOUT / 5)) ]; then
        print_warning "TLS certificate may not be ready yet (timeout after ${CERT_TIMEOUT}s)"
        print_status "Check status with: kubectl get certificate -n $NS_WEBMAIL"
    fi
    sleep 5
done

print_success "Roundcube Webmail deployed successfully for $MT_ENV environment"
echo ""
print_status "Namespace: $NS_WEBMAIL"
print_status "Webmail URL: https://${WEBMAIL_HOST}"
print_status "Authentication: Keycloak SSO via ${AUTH_HOST}/realms/${KEYCLOAK_REALM}"
print_status "Mail Server: Stalwart at ${MAIL_HOST}"
echo ""
print_status "To check status: kubectl get pods -n $NS_WEBMAIL"
print_status "To view logs: kubectl logs -n $NS_WEBMAIL -l app=roundcube -f"
