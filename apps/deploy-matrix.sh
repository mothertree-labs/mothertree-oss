#!/bin/bash

# Deploy Matrix (Synapse + Element) using Helmfile and static Kubernetes manifests
# This script handles all Matrix-related deployment including database init,
# Element branding, Helm releases, Synapse Admin, and federation setup.
#
# Namespace structure:
#   - Synapse, Element, Synapse Admin in NS_MATRIX (e.g., 'tn-example-matrix')
#
# Prerequisites:
#   - PostgreSQL database deployed in infra-db namespace
#   - Keycloak deployed and configured
#   - Helm repos available (ananace)
#
# Usage:
#   ./apps/deploy-matrix.sh -e dev -t example
#   ./apps/deploy-matrix.sh -e prod -t example --create-alert-user

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant> [options]"
    echo ""
    echo "Deploy Matrix (Synapse + Element) for a tenant."
    echo ""
    echo "Options:"
    echo "  -e <env>              Environment (e.g., dev, prod)"
    echo "  -t <tenant>           Tenant name (e.g., example)"
    echo "  --create-alert-user   Create the alertbot Matrix user for alerting"
    echo "  -h, --help            Show this help"
}

mt_parse_args "$@"
mt_require_env
mt_require_tenant

source "${REPO_ROOT}/scripts/lib/config.sh"
mt_load_tenant_config

source "${REPO_ROOT}/scripts/lib/notify.sh"
mt_deploy_start "deploy-matrix"

mt_require_commands kubectl envsubst helmfile

# Check --create-alert-user flag
CREATE_ALERT_USER="false"
if mt_has_flag "--create-alert-user"; then
  CREATE_ALERT_USER="true"
fi

print_status "Deploying Matrix (Synapse + Element) for environment: $MT_ENV"
print_status "Tenant: $TENANT"
print_status "Matrix namespace: $NS_MATRIX"
print_status "Matrix host: $MATRIX_HOST"
print_status "Synapse host: $SYNAPSE_HOST"
if [ "$CREATE_ALERT_USER" = "true" ]; then
  print_status "Alertbot Matrix user will be created"
fi

# Validate PG_HOST
if [ -z "${PG_HOST:-}" ]; then
    print_error "PostgreSQL not found. Run 'deploy_infra $MT_ENV' first."
    exit 1
fi

# Ensure helm repos are available
if [ "${MT_NESTING_LEVEL:-0}" -eq 0 ]; then
  print_status "Updating Helm repositories..."
  helm repo add ananace https://ananace.gitlab.io/charts/ 2>/dev/null || true
  helm repo update >/dev/null 2>&1
fi

# Ensure namespace exists
print_status "Ensuring $NS_MATRIX namespace exists..."
kubectl create namespace "$NS_MATRIX" --dry-run=client -o yaml | kubectl apply -f -

# =============================================================================
# Initialize Synapse database on shared PostgreSQL
# =============================================================================
print_status "Initializing Synapse database on shared PostgreSQL..."
print_status "Synapse DB: $SYNAPSE_DB_NAME (user: $SYNAPSE_DB_USER)"

# Copy the PostgreSQL admin secret from infra-db namespace
print_status "Copying PostgreSQL admin secret to $NS_MATRIX namespace..."
PG_PASSWORD=$(kubectl get secret docs-postgresql -n "$NS_DB" -o jsonpath='{.data.postgres-password}')
if [ -z "$PG_PASSWORD" ]; then
  print_error "Could not retrieve PostgreSQL admin password from $NS_DB namespace"
  exit 1
fi
kubectl create secret generic docs-postgresql \
    --namespace="$NS_MATRIX" \
    --from-literal=postgres-password="$(echo "$PG_PASSWORD" | base64 -d)" \
    --dry-run=client -o yaml | kubectl apply -f -
print_status "PostgreSQL admin secret copied to $NS_MATRIX"

# Create synapse-db-secrets for the db-init job
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: synapse-db-secrets
  namespace: $NS_MATRIX
type: Opaque
stringData:
  SYNAPSE_DB_PASSWORD: "$SYNAPSE_DB_PASSWORD"
EOF
print_status "Synapse DB secrets applied"

# Delete any previous db-init job (jobs are immutable)
if kubectl get job synapse-db-init -n "$NS_MATRIX" >/dev/null 2>&1; then
  print_status "Deleting previous synapse-db-init job..."
  kubectl delete job synapse-db-init -n "$NS_MATRIX" --force --grace-period=0 2>/dev/null || true
  kubectl delete pods -n "$NS_MATRIX" -l job-name=synapse-db-init --force --grace-period=0 2>/dev/null || true
  for i in $(seq 1 60); do
    if ! kubectl get job synapse-db-init -n "$NS_MATRIX" >/dev/null 2>&1; then
      break
    fi
    if [ $i -eq 60 ]; then
      print_error "Timeout waiting for synapse-db-init job deletion"
      exit 1
    fi
    sleep 1
  done
fi

# Run the database initialization job
print_status "Running Synapse database initialization job..."
envsubst '${NS_MATRIX} ${SYNAPSE_DB_NAME} ${SYNAPSE_DB_USER} ${PG_HOST}' \
    < "$REPO_ROOT/apps/manifests/synapse/db-init-job.yaml.tpl" | kubectl create -f -

# Wait for job completion
if kubectl wait --for=condition=complete job/synapse-db-init -n "$NS_MATRIX" --timeout=120s 2>/dev/null; then
  print_status "Synapse database initialization completed successfully"
else
  JOB_STATUS=$(kubectl get job synapse-db-init -n "$NS_MATRIX" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
  if [ "$JOB_STATUS" = "True" ]; then
    print_error "Synapse database initialization job failed"
    print_status "Job logs:"
    kubectl logs -n "$NS_MATRIX" job/synapse-db-init || true
    exit 1
  else
    print_warning "Synapse database initialization may not have completed (timeout)"
    print_status "Check job status: kubectl get job synapse-db-init -n $NS_MATRIX"
  fi
fi

# =============================================================================
# Element branding ConfigMap
# =============================================================================
# Must exist before helmfile sync so pods can mount these files
print_status "Creating Element branding ConfigMap..."
FONTS_DIR="$REPO_ROOT/apps/account-portal/public/fonts"
ASSETS_DIR="$REPO_ROOT/apps/account-portal/public"
kubectl -n "$NS_MATRIX" create configmap element-branding \
    --from-file=favicon.svg="$ASSETS_DIR/favicon.svg" \
    --from-file=logo.svg="$ASSETS_DIR/favicon.svg" \
    --from-file=figtree-latin.woff2="$FONTS_DIR/figtree-latin.woff2" \
    --from-file=figtree-latin-ext.woff2="$FONTS_DIR/figtree-latin-ext.woff2" \
    --from-file=figtree-italic-latin.woff2="$FONTS_DIR/figtree-italic-latin.woff2" \
    --from-file=figtree-italic-latin-ext.woff2="$FONTS_DIR/figtree-italic-latin-ext.woff2" \
    --dry-run=client -o yaml | kubectl apply -f -
print_status "Element branding ConfigMap created in namespace $NS_MATRIX"

# =============================================================================
# Deploy Synapse and Element via helmfile
# =============================================================================
print_status "Apps: helmfile sync (Synapse, Element)"
pushd "$REPO_ROOT/apps" >/dev/null
  SKIP_DEPS_FLAG=""
  if [ "${MT_NESTING_LEVEL:-0}" -gt 0 ]; then
    SKIP_DEPS_FLAG="--skip-deps"
  fi
  max_retries=3
  retry_count=0
  while [ $retry_count -lt $max_retries ]; do
    if helmfile -e "$MT_ENV" -l "component=matrix" sync $SKIP_DEPS_FLAG; then
      break
    fi
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $max_retries ]; then
      print_warning "helmfile sync failed (attempt $retry_count/$max_retries), retrying in 10 seconds..."
      sleep 10
    else
      print_error "helmfile sync failed after $max_retries attempts"
      exit 1
    fi
  done
popd >/dev/null

# =============================================================================
# Element HPA and ingress
# =============================================================================
# Deploy Element HPA (only if min != max replicas)
if [ "$ELEMENT_MIN_REPLICAS" != "$ELEMENT_MAX_REPLICAS" ]; then
  print_status "Deploying Element HPA..."
  envsubst < "$REPO_ROOT/apps/manifests/element/element-hpa.yaml.tpl" | kubectl apply -f -
  print_status "Element HPA deployed (CPU 80% threshold)"
else
  kubectl delete hpa element-hpa -n "$NS_MATRIX" --ignore-not-found >/dev/null 2>&1
  print_status "Element: fixed replicas ($ELEMENT_MIN_REPLICAS), HPA removed"
fi

# Deploy Element static cache ingress (immutable cache for webpack bundles)
print_status "Deploying Element static cache ingress..."
envsubst < "$REPO_ROOT/apps/manifests/element/element-static-cache-ingress.yaml.tpl" | kubectl apply -f -
print_status "Element static cache ingress deployed"

# =============================================================================
# Keycloak tenant auth ingress
# =============================================================================
# Each tenant gets their own ingress resource pointing to the shared Keycloak service.
# This avoids field manager conflicts that occur when patching a Helm-managed ingress.
print_status "Keycloak: Creating tenant auth ingress for $AUTH_HOST"
envsubst '${AUTH_HOST} ${TENANT} ${NS_AUTH} ${TENANT_DOMAIN} ${TENANT_NAME}' < "$REPO_ROOT/apps/manifests/keycloak/tenant-auth-ingress.yaml.tpl" | kubectl apply -f -
print_status "Tenant auth ingress created: keycloak-${TENANT}"

# Show all auth ingresses
print_status "All Keycloak auth ingresses:"
kubectl get ingress -n "$NS_AUTH" -l app=keycloak -o custom-columns='NAME:.metadata.name,HOST:.spec.rules[*].host'

# =============================================================================
# Synapse Admin
# =============================================================================
print_status "Synapse Admin: deploying to $NS_MATRIX namespace..."
export MATRIX_REGISTRATION_SHARED_SECRET="$SYNAPSE_REGISTRATION_SHARED_SECRET"
envsubst < "$REPO_ROOT/apps/manifests/synapse-admin/synapse-admin.yaml.tpl" | kubectl apply -f -
# Deploy HPA for synapse-admin auto-scaling (only if min != max replicas)
if [ "$SYNAPSE_ADMIN_MIN_REPLICAS" != "$SYNAPSE_ADMIN_MAX_REPLICAS" ]; then
  envsubst < "$REPO_ROOT/apps/manifests/synapse-admin/synapse-admin-hpa.yaml.tpl" | kubectl apply -f -
  print_status "Synapse Admin HPA deployed (CPU 80% threshold)"
else
  kubectl delete hpa synapse-admin-hpa -n "$NS_MATRIX" --ignore-not-found >/dev/null 2>&1
  print_status "Synapse Admin: fixed replicas ($SYNAPSE_ADMIN_MIN_REPLICAS), HPA removed"
fi
kubectl -n "$NS_MATRIX" wait --for=condition=available deployment/synapse-admin --timeout=120s || print_warning "Synapse Admin may not be fully ready"
print_status "Synapse Admin deployed to https://$SYNAPSE_ADMIN_HOST"

# =============================================================================
# Matrix federation .well-known (prod only)
# =============================================================================
if [ -z "$TENANT_ENV_DNS_LABEL" ] || [ "$TENANT_ENV_DNS_LABEL" = "null" ]; then
  print_status "Deploying Matrix .well-known ingress for federation on $TENANT_DOMAIN..."
  envsubst < "$REPO_ROOT/apps/manifests/synapse-admin/matrix-wellknown.yaml.tpl" | kubectl apply -f -
  print_status "Matrix federation .well-known endpoints available at https://$TENANT_DOMAIN/.well-known/matrix/*"
else
  print_status "Skipping .well-known ingress (dev environment uses matrix subdomain for federation)"
fi

# =============================================================================
# Alertbot user (optional)
# =============================================================================
if [ "$CREATE_ALERT_USER" = "true" ]; then
  print_status "Creating alertbot Matrix user for alerting..."
  if [ -f "$REPO_ROOT/apps/scripts/create-alertbot-user.sh" ]; then
    print_status "Waiting for Synapse to be ready..."
    kubectl -n "$NS_MATRIX" wait --for=condition=available deployment -l app.kubernetes.io/name=matrix-synapse --timeout=300s || print_warning "Synapse may not be fully ready"

    if "$REPO_ROOT/apps/scripts/create-alertbot-user.sh" -e "$MT_ENV" -t "$MT_TENANT" --save; then
      print_status "Alertbot user created and token saved"
      # Reload the token from secrets (subprocess can't export back to parent)
      MATRIX_ALERTMANAGER_ACCESS_TOKEN=$(yq '.alertbot.access_token // ""' "$TENANT_SECRETS")
      if [ -n "$MATRIX_ALERTMANAGER_ACCESS_TOKEN" ] && [ "$MATRIX_ALERTMANAGER_ACCESS_TOKEN" != "null" ]; then
        export MATRIX_ALERTMANAGER_ACCESS_TOKEN
      fi
    else
      print_warning "Failed to create alertbot user (non-fatal, continuing)"
    fi
  else
    print_warning "create-alertbot-user.sh not found, skipping alertbot creation"
  fi
fi

# NOTE: matrix-alertmanager (deploy-alerting.sh) is deployed by deploy_infra, not here.
# It's shared infrastructure that should not be overwritten per-tenant.

print_success "Matrix (Synapse + Element) deployed successfully for $MT_ENV environment"
print_status "Namespace: $NS_MATRIX"
print_status "Matrix: https://$MATRIX_HOST"
print_status "Synapse Admin: https://$SYNAPSE_ADMIN_HOST (VPN only)"
