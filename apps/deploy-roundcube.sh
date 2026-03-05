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
#
# Usage:
#   ./apps/deploy-roundcube.sh -e dev -t example

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy Roundcube Webmail for a tenant."
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

source "${REPO_ROOT}/scripts/lib/paths.sh"
_mt_resolve_project_conf
[[ -n "$MT_PROJECT_CONF" ]] && source "$MT_PROJECT_CONF"

source "${REPO_ROOT}/scripts/lib/notify.sh"
mt_deploy_start "deploy-roundcube"

mt_require_commands kubectl envsubst

# Override NS_MAIL for envsubst templates that use ${NS_MAIL} to mean
# the tenant mail namespace (roundcube templates reference stalwart service there)
export NS_MAIL="$NS_STALWART"

print_status "Deploying Roundcube Webmail for environment: $MT_ENV"
print_status "Tenant: $TENANT"
print_status "Webmail namespace: $NS_WEBMAIL"
print_status "Mail namespace: $NS_MAIL"

# Check if webmail_enabled feature flag is set
if [ "$WEBMAIL_ENABLED" != "true" ]; then
    print_warning "Webmail not enabled for tenant $TENANT (features.webmail_enabled is not true)"
    print_warning "Skipping Roundcube deployment"
    exit 0
fi

# Check if mail is enabled (required for webmail)
if [ "$MAIL_ENABLED" != "true" ]; then
    print_error "Mail is not enabled for tenant $TENANT but webmail is."
    print_error "Enable 'features.mail_enabled' in tenant config first."
    exit 1
fi

# Validate database config
if [ -z "$ROUNDCUBE_DB_NAME" ] || [ "$ROUNDCUBE_DB_NAME" = "null" ]; then
    print_error "ROUNDCUBE_DB_NAME not set. Add 'database.roundcube_db' to tenant config"
    exit 1
fi
print_status "Database: $ROUNDCUBE_DB_NAME (user: $ROUNDCUBE_DB_USER)"

# Validate PG_HOST
if [ -z "${PG_HOST:-}" ]; then
    print_error "PostgreSQL not found. Run 'deploy_infra $MT_ENV' first."
    exit 1
fi

print_status "Webmail host: $WEBMAIL_HOST"
print_status "Mail host: $MAIL_HOST"
print_status "Files host (CalDAV): $FILES_HOST"
print_status "Auth host: $AUTH_HOST"

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
    print_error "Update tenant secrets file with actual values"
    exit 1
fi

# Generate config checksum for pod annotations.
# Includes both secrets AND the rendered config template to trigger pod restarts
# on any config change (not just secret rotation).
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

# =============================================================================
# Load Roundcube image tag from CI-built tags (or fall back to :latest)
# =============================================================================
export CONTAINER_REGISTRY="${CONTAINER_REGISTRY:-ghcr.io/YOUR_ORG}"
source "${REPO_ROOT}/scripts/lib/image-tags.sh"
_mt_load_image_tags
print_status "Roundcube image: $ROUNDCUBE_IMAGE"

# Apply Roundcube manifests
print_status "Applying Roundcube manifests..."

# Apply main Roundcube manifest (Secret, ConfigMap, Deployment, Service).
# Use explicit variable list to preserve PHP $config variables in the ConfigMap —
# without it, envsubst would substitute $config with empty strings, breaking Roundcube.
envsubst '${NS_WEBMAIL} ${NS_MAIL} ${AUTH_HOST} ${KEYCLOAK_REALM} ${KEYCLOAK_INTERNAL_URL} ${ROUNDCUBE_DES_KEY} ${TENANT_DISPLAY_NAME} ${ROUNDCUBE_DB_USER} ${ROUNDCUBE_DB_NAME} ${TENANT_NAME} ${ROUNDCUBE_OIDC_SECRET} ${ROUNDCUBE_DB_PASSWORD} ${ROUNDCUBE_MEMORY_REQUEST} ${ROUNDCUBE_MEMORY_LIMIT} ${ROUNDCUBE_CPU_REQUEST} ${CONFIG_CHECKSUM} ${FILES_HOST} ${ROUNDCUBE_MIN_REPLICAS} ${PG_HOST} ${ROUNDCUBE_IMAGE}' \
    < "$REPO_ROOT/apps/manifests/roundcube/roundcube.yaml.tpl" | kubectl apply -f -
print_success "Roundcube Deployment and Service applied"

# Deploy HorizontalPodAutoscaler (HPA) for auto-scaling
print_status "Deploying HPA for Roundcube..."
envsubst < "$REPO_ROOT/apps/manifests/roundcube/roundcube-hpa.yaml.tpl" | kubectl apply -f -
print_success "Roundcube HPA deployed (CPU 80% threshold)"

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


print_success "Roundcube Webmail deployed successfully for $MT_ENV environment"
echo ""
print_status "Namespace: $NS_WEBMAIL"
print_status "Webmail URL: https://${WEBMAIL_HOST}"
print_status "Authentication: Keycloak SSO via ${AUTH_HOST}/realms/${KEYCLOAK_REALM}"
print_status "Mail Server: Stalwart at ${MAIL_HOST}"
echo ""
print_status "To check status: kubectl get pods -n $NS_WEBMAIL"
print_status "To view logs: kubectl logs -n $NS_WEBMAIL -l app=roundcube -f"
