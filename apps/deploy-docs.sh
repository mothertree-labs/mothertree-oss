#!/bin/bash

# Deploy LaSuite Docs to Kubernetes
# This script handles the complete deployment of Docs alongside Matrix
#
# Namespace structure:
#   - PostgreSQL goes to NS_DB (shared 'db' namespace)
#   - Docs apps go to NS_DOCS (tenant-prefixed namespace, e.g., 'tn-example-docs')
#
# Usage:
#   ./apps/deploy-docs.sh -e dev -t example

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy LaSuite Docs for a tenant."
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
mt_deploy_start "deploy-docs"

mt_require_commands kubectl helm envsubst openssl

print_status "Starting LaSuite Docs deployment..."
print_status "Database namespace: $NS_DB"
print_status "Docs app namespace: $NS_DOCS"

# Create namespaces if they don't exist
kubectl create namespace "$NS_DB" 2>/dev/null || true
kubectl create namespace "$NS_DOCS" 2>/dev/null || true

# Step 1: Create S3 bucket (skipped)
print_status "Skipping S3 bucket creation (managed externally)"

# Step 2: Verify PostgreSQL (detected by config.sh)
if [ -z "${PG_HOST:-}" ]; then
  print_error "PostgreSQL not found in $NS_DB namespace."
  print_error "Please run 'deploy_infra $MT_ENV' first to deploy shared infrastructure."
  exit 1
fi
print_status "PostgreSQL service: ${PG_HOST}"

# Verify PostgreSQL is ready
print_status "Verifying PostgreSQL is ready..."
if ! kubectl get pod -n "$NS_DB" -l app.kubernetes.io/name=postgresql -o name 2>/dev/null | head -1 | xargs -I{} kubectl wait --for=condition=ready {} -n "$NS_DB" --timeout=60s 2>/dev/null; then
  print_error "PostgreSQL is not ready. Check deploy_infra logs."
  exit 1
fi
print_success "PostgreSQL is ready"

# Step 3: Get database password
print_status "Retrieving database password..."
DB_PASSWORD=$(kubectl get secret docs-postgresql -n "$NS_DB" -o jsonpath='{.data.postgres-password}' | base64 -d)
if [ -z "$DB_PASSWORD" ]; then
    print_error "Failed to retrieve database password"
    exit 1
fi
print_success "Database password retrieved"

# Step 4: Configure secrets for Docs (idempotent)
print_status "Configuring secrets for Docs (idempotent)..."

# Resolve S3 credentials (prefer docs-specific, fallback to main linode object storage keys)
if [ -n "${TF_VAR_docs_s3_access_key:-}" ] && [ -n "${TF_VAR_docs_s3_secret_key:-}" ]; then
  AWS_ACCESS_KEY_ID="$TF_VAR_docs_s3_access_key"
  AWS_SECRET_ACCESS_KEY="$TF_VAR_docs_s3_secret_key"
  print_status "Using docs-specific S3 credentials"
elif [ -n "${TF_VAR_linode_object_storage_access_key:-}" ] && [ -n "${TF_VAR_linode_object_storage_secret_key:-}" ]; then
  AWS_ACCESS_KEY_ID="$TF_VAR_linode_object_storage_access_key"
  AWS_SECRET_ACCESS_KEY="$TF_VAR_linode_object_storage_secret_key"
  print_status "Using primary Linode Object Storage credentials"
else
  print_error "No S3 credentials found. Set TF_VAR_docs_s3_access_key/TF_VAR_docs_s3_secret_key."
  exit 1
fi

# Resolve Django secret key (preserve existing if present)
DJANGO_SECRET_KEY=$(kubectl -n "$NS_DOCS" get secret docs-secrets -o jsonpath='{.data.DJANGO_SECRET_KEY}' 2>/dev/null | base64 -d || true)
if [ -z "$DJANGO_SECRET_KEY" ]; then
  DJANGO_SECRET_KEY=$(openssl rand -base64 48)
  print_status "Generated new Django secret key"
fi

# Resolve collaboration server secret (preserve existing if present)
COLLABORATION_SERVER_SECRET=$(kubectl -n "$NS_DOCS" get secret docs-secrets -o jsonpath='{.data.COLLABORATION_SERVER_SECRET}' 2>/dev/null | base64 -d || true)
if [ -z "$COLLABORATION_SERVER_SECRET" ]; then
  COLLABORATION_SERVER_SECRET=$(openssl rand -hex 32)
  print_status "Generated COLLABORATION_SERVER_SECRET"
fi

# Resolve y-provider API key (preserve existing if present)
Y_PROVIDER_API_KEY=$(kubectl -n "$NS_DOCS" get secret docs-secrets -o jsonpath='{.data.Y_PROVIDER_API_KEY}' 2>/dev/null | base64 -d || true)
if [ -z "$Y_PROVIDER_API_KEY" ]; then
  Y_PROVIDER_API_KEY=$(openssl rand -hex 32)
  print_status "Generated Y_PROVIDER_API_KEY"
fi

# Create or update the docs-secrets secret
kubectl create secret generic docs-secrets \
  --from-literal=DJANGO_SECRET_KEY="$DJANGO_SECRET_KEY" \
  --from-literal=DATABASE_PASSWORD="$DB_PASSWORD" \
  --from-literal=AWS_S3_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_S3_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=OIDC_RP_CLIENT_SECRET="${TF_VAR_oidc_rp_client_secret_docs:-$(kubectl -n "$NS_DOCS" get secret docs-secrets -o jsonpath='{.data.OIDC_RP_CLIENT_SECRET}' 2>/dev/null | base64 -d)}" \
  --from-literal=COLLABORATION_SERVER_SECRET="$COLLABORATION_SERVER_SECRET" \
  --from-literal=Y_PROVIDER_API_KEY="$Y_PROVIDER_API_KEY" \
  -n "$NS_DOCS" \
  --dry-run=client -o yaml | kubectl apply -f -

print_success "Secrets configured successfully"

# Step 5: Deploy simple Redis service to tenant docs namespace
# Note: Redis for docs is tenant-specific for data isolation
print_status "Deploying Redis service for backend to namespace $NS_DOCS..."
cat "$REPO_ROOT/docs/redis-deployment.yaml" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
cat "$REPO_ROOT/docs/redis-service.yaml" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
poll_pod_ready "$NS_DOCS" "io.kompose.service=redis" 60 5 || true
print_success "Redis service deployed to namespace $NS_DOCS"

# Step 6: Apply Docs manifests (backend, frontend, ingress) to tenant namespace
print_status "Applying Docs manifests to namespace $NS_DOCS..."
print_status "Using environment: DOCS_HOST=$DOCS_HOST, AUTH_HOST=$AUTH_HOST"
print_status "Database user: $TENANT_DB_USER, Database: $DOCS_DB_NAME"

# Apply manifests with namespace substitution
cat "$REPO_ROOT/docs/storage-backends-configmap.yaml" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
cat "$REPO_ROOT/docs/save-status-configmap.yaml" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
envsubst < "$REPO_ROOT/docs/env-d-yprovider-configmap.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
envsubst < "$REPO_ROOT/docs/docs-config.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -

# Create invitation patch ConfigMap (patches Docs email links to go through admin portal)
kubectl -n "$NS_DOCS" create configmap docs-invitation-patch \
  --from-file=patch_invitation.py="$REPO_ROOT/docs/patch_invitation.py" \
  --dry-run=client -o yaml | kubectl apply -f -

# Update backend deployment to reference PostgreSQL in db namespace
# Uses envsubst for replica count from tenant config
envsubst '${DOCS_BACKEND_MIN_REPLICAS}' < "$REPO_ROOT/docs/backend-deployment.yaml" | \
  sed "s/namespace: docs/namespace: $NS_DOCS/g" | \
  sed "s/docs-postgresql.docs.svc/${PG_SERVICE_NAME}.$NS_DB.svc/g" | \
  kubectl apply -f -
cat "$REPO_ROOT/docs/backend-service.yaml" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -

# Deploy frontend with environment-specific configuration (includes replica count)
envsubst < "$REPO_ROOT/docs/frontend-deployment.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
cat "$REPO_ROOT/docs/frontend-service.yaml" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
envsubst < "$REPO_ROOT/docs/ingress.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
# Static asset cache ingress (/_next/static/ with immutable cache headers)
envsubst < "$REPO_ROOT/docs/static-cache-ingress.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
# Y-Provider ingress with document ID-based consistent hashing for WebSocket scaling
# Use explicit variable list to preserve nginx $request_uri variable
envsubst '${DOCS_HOST} ${TENANT_NAME}' < "$REPO_ROOT/docs/yprovider-ingress.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
print_success "Docs manifests applied successfully to namespace $NS_DOCS"

# Step 7: Restart deployments to pick up ConfigMap changes, then wait for ready (PARALLEL)
print_status "Restarting backend and frontend to pick up ConfigMap changes..."
kubectl -n "$NS_DOCS" rollout restart deployment/backend deployment/frontend
print_status "Waiting for Docs backend and frontend to be ready (parallel)..."
# Wait for both in parallel
kubectl -n "$NS_DOCS" rollout status deployment/backend --timeout=300s &
BACKEND_PID=$!
kubectl -n "$NS_DOCS" rollout status deployment/frontend --timeout=300s &
FRONTEND_PID=$!
wait $BACKEND_PID $FRONTEND_PID
print_success "Docs backend and frontend are ready"

# Step 8: Deploy/Update y-provider (declarative)
print_status "Applying y-provider deployment and service to namespace $NS_DOCS..."
cat "$REPO_ROOT/docs/health-sidecar-configmap.yaml" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
# Uses envsubst for replica count from tenant config
envsubst '${YPROVIDER_MIN_REPLICAS}' < "$REPO_ROOT/docs/y-provider-deployment.yaml" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
cat "$REPO_ROOT/docs/y-provider-service.yaml" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
# Restart to ensure ConfigMap changes are picked up (wait in background, check later)
kubectl -n "$NS_DOCS" rollout restart deploy/docs-y-provider
kubectl -n "$NS_DOCS" rollout status deploy/docs-y-provider --timeout=300s &
YPROVIDER_PID=$!
# Wait for y-provider rollout to complete
wait $YPROVIDER_PID
# Quick sanity: short endpoint check (non-fatal; kube liveness covers steady state)
print_status "Checking y-provider service endpoints..."
if kubectl -n "$NS_DOCS" get endpoints y-provider -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -qE '[0-9]'; then
  kubectl -n "$NS_DOCS" get endpoints y-provider
else
  print_warning "y-provider endpoints not yet reported; rely on rollout status/liveness"
fi
print_success "y-provider applied successfully"

# Step 8a: Deploy HorizontalPodAutoscalers (HPA) for auto-scaling
print_status "Deploying HPAs for docs backend, frontend, and y-provider..."
envsubst < "$REPO_ROOT/docs/backend-hpa.yaml.tpl" | kubectl apply -f -
envsubst < "$REPO_ROOT/docs/frontend-hpa.yaml.tpl" | kubectl apply -f -
envsubst < "$REPO_ROOT/docs/yprovider-hpa.yaml.tpl" | kubectl apply -f -
print_success "Docs HPAs deployed (CPU 80% threshold)"

# Step 8b: Deploy Grafana dashboard for Docs monitoring
print_status "Deploying Docs Grafana dashboard..."
cat "$REPO_ROOT/apps/manifests/docs/docs-dashboard-configmap.yaml" | sed "s/namespace: monitoring/namespace: $NS_MONITORING/g" | kubectl apply -f -
print_success "Docs Grafana dashboard deployed"

# Step 9: Initialize/verify database (idempotent)
# The db-init job runs in NS_DOCS (where docs-secrets is) and connects to PostgreSQL cross-namespace
print_status "Ensuring docs role/database exist and privileges set..."

# Copy postgres-password from NS_DB to NS_DOCS so the job can access it
print_status "Copying PostgreSQL credentials to docs namespace for db-init job..."
POSTGRES_PASSWORD=$(kubectl get secret docs-postgresql -n "$NS_DB" -o jsonpath='{.data.postgres-password}' | base64 -d 2>/dev/null || echo "")
if [ -z "$POSTGRES_PASSWORD" ]; then
    print_error "Could not get postgres-password from docs-postgresql secret in $NS_DB"
    exit 1
fi
kubectl create secret generic docs-postgresql \
    --from-literal=postgres-password="$POSTGRES_PASSWORD" \
    -n "$NS_DOCS" \
    --dry-run=client -o yaml | kubectl apply -f -

# Wait for cross-namespace DNS before running db-init job
print_status "Waiting for DNS resolution of PostgreSQL service..."
if wait_for_dns "$NS_DOCS" "$PG_HOST" 60 5; then
    print_success "DNS resolution working"
else
    print_warning "DNS check timed out, proceeding anyway (job has retries)"
fi

kubectl -n "$NS_DOCS" delete job/docs-db-init --ignore-not-found=true || true
envsubst '${DOCS_DB_NAME} ${TENANT_DB_USER} ${PG_HOST} ${KEYCLOAK_DB_PASSWORD}' < "$REPO_ROOT/docs/db-init-job.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
if ! poll_job_complete "$NS_DOCS" "docs-db-init" 180 5; then
    print_error "Database initialization failed"
    exit 1
fi
print_success "Database role/database verified"

# Step 9b: Sync password from docs-secrets to docs-postgresql secret
# This ensures the docs-postgresql secret has the correct password matching docs-secrets.DATABASE_PASSWORD
# The db-init-job sets the actual PostgreSQL password, this step syncs the Kubernetes secret
print_status "Syncing database password to docs-postgresql secret..."
DOCS_USER_PASSWORD=$(kubectl get secret docs-secrets -n "$NS_DOCS" -o jsonpath='{.data.DATABASE_PASSWORD}' | base64 -d 2>/dev/null || echo "")
if [ -n "$DOCS_USER_PASSWORD" ]; then
    # Get the existing postgres-password (superuser) to preserve it
    POSTGRES_PASSWORD=$(kubectl get secret docs-postgresql -n "$NS_DB" -o jsonpath='{.data.postgres-password}' | base64 -d)
    # Recreate the secret with the correct password for the docs user
    kubectl create secret generic docs-postgresql \
        --namespace "$NS_DB" \
        --from-literal=postgres-password="$POSTGRES_PASSWORD" \
        --from-literal=password="$DOCS_USER_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    print_success "docs-postgresql secret synced with correct password"
else
    print_warning "Could not retrieve DATABASE_PASSWORD from docs-secrets, skipping sync"
fi

# Step 10: Run database migrations
print_status "Running Django database migrations..."
kubectl -n "$NS_DOCS" delete job/docs-migrations --ignore-not-found=true || true
cat "$REPO_ROOT/docs/migrations-job.yaml" | \
  sed "s/namespace: docs/namespace: $NS_DOCS/g" | \
  sed "s/docs-postgresql.docs.svc/${PG_SERVICE_NAME}.$NS_DB.svc/g" | \
  kubectl apply -f -
if ! poll_job_complete "$NS_DOCS" "docs-migrations" 300 5; then
    print_error "Database migrations failed"
    exit 1
fi
print_success "Database migrations completed"

# Step 10b: Set Django Site domain for email links
print_status "Setting Django Site domain..."
BACKEND_POD=$(kubectl -n "$NS_DOCS" get pods -l app=backend --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$BACKEND_POD" ]; then
    kubectl -n "$NS_DOCS" exec "$BACKEND_POD" -- python manage.py shell -c "
from django.contrib.sites.models import Site
site = Site.objects.get(pk=1)
site.domain = 'https://${DOCS_HOST}'
site.name = '${TENANT_DISPLAY_NAME:-MotherTree} Docs'
site.save()
print(f'Site domain set to: {site.domain}')
" 2>/dev/null && print_success "Django Site domain configured" || print_warning "Failed to set Site domain (non-critical)"
else
    print_warning "No running backend pod found, skipping Site domain configuration"
fi

# Step 11: Keycloak realm import is done in create_env script after Keycloak is deployed
# (Keycloak is deployed via helmfile in create_env, after deploy-docs.sh completes)
print_status "Skipping Keycloak realm import (done in create_env after Keycloak deployment)"

# Step 12: Create superuser (skipped if manifest not present)
if [ -f "$REPO_ROOT/docs/superuser-job.yaml" ]; then
  print_status "Creating superuser account..."
  cat "$REPO_ROOT/docs/superuser-job.yaml" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
  if poll_job_complete "$NS_DOCS" "docs-superuser" 300 5; then
    print_success "Superuser created successfully"
  else
    print_warning "Superuser creation may have failed, continuing..."
  fi
else
  print_status "Skipping superuser creation (manifest not present)"
fi

# Step 13: Verify deployment
print_status "Verifying Docs deployment..."

# Show resource snapshot
echo ""
echo "Resources in database namespace ($NS_DB):"
kubectl get deploy,svc -n "$NS_DB"
echo ""
echo "Resources in docs namespace ($NS_DOCS):"
kubectl get deploy,svc,ingress -n "$NS_DOCS"

# Step 14: Display access information
print_success "LaSuite Docs deployment completed successfully!"
echo ""
echo "Access Information:"
echo "  URL: https://$DOCS_HOST"
echo "  Admin Username: admin"
echo "  Admin Password: (set via DJANGO_SUPERUSER_PASSWORD in docs-secrets)"
echo "  Admin Email: admin@${BASE_DOMAIN}"
echo ""
echo "Namespace Information:"
echo "  Database namespace: $NS_DB"
echo "  Docs app namespace: $NS_DOCS"
echo ""
echo "To check the status:"
echo "  kubectl get pods -n $NS_DOCS"
echo "  kubectl get ingress -n $NS_DOCS"
echo "  kubectl logs -f deployment/backend -n $NS_DOCS"
echo "  kubectl logs -f deployment/frontend -n $NS_DOCS"
