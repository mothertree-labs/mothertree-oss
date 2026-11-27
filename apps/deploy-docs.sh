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
# shellcheck source=../scripts/lib/platform.sh
source "${REPO_ROOT}/scripts/lib/platform.sh"
mt_deploy_start "deploy-docs"

mt_require_commands kubectl helm envsubst openssl jq yq

# Track config changes to avoid restarting pods unnecessarily
mt_reset_change_tracker

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

# Verify PgBouncer is ready (sole entrypoint to external PG VM)
print_status "Verifying PgBouncer is ready..."
if ! kubectl wait --for=condition=ready pod -l app=pgbouncer -n "$NS_DB" --timeout=60s 2>/dev/null; then
  print_error "PgBouncer is not ready. Check deploy_infra logs."
  exit 1
fi
print_success "PgBouncer is ready"

# Step 3: Get database superuser password
print_status "Retrieving database password..."
DB_PASSWORD=$(mt_pg_password)
if [ -z "$DB_PASSWORD" ]; then
    print_error "Failed to retrieve postgres-credentials secret from $NS_DB"
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

# impress >= 6 dropped COLLABORATION_SERVER_SECRET on both sides: the backend
# and the collaboration server (yhub) authenticate each other with RS256 JWTs,
# each signing with a key of its own and publishing the public half (backend:
# /api/v1.0/jwks, yhub: /collaboration/jwks/v1). The old key simply stops
# being written into docs-secrets below.

# Existing RSA private key from <secret>/<key>, or a new 2048-bit one when the
# Secret has none (first deploy). Status goes to stderr: stdout is the PEM.
_docs_rsa_key() {
  local secret="$1" key="$2" pem
  pem=$(kubectl -n "$NS_DOCS" get secret "$secret" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d || true)
  if [ -z "$pem" ]; then
    pem=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null) || {
      print_error "Could not generate an RSA key for $secret/$key" >&2; return 1; }
    print_status "Generated a new RSA signing key ($secret/$key)" >&2
  fi
  printf '%s\n' "$pem" | openssl pkey -noout 2>/dev/null || {
    print_error "$secret/$key does not hold a valid private key" >&2; return 1; }
  printf '%s\n' "$pem"
}

# Backend signing key (JWT_PRIVATE_KEY_FILE, mounted from docs-secrets).
JWT_PRIVATE_KEY=$(_docs_rsa_key docs-secrets JWT_PRIVATE_KEY) || exit 1
# yhub signing key, deliberately a different key (Secret docs-yhub).
YHUB_JWT_PRIVATE_KEY=$(_docs_rsa_key docs-yhub YHUB_JWT_PRIVATE_KEY) || exit 1

# Resolve y-provider API key (preserve existing if present)
Y_PROVIDER_API_KEY=$(kubectl -n "$NS_DOCS" get secret docs-secrets -o jsonpath='{.data.Y_PROVIDER_API_KEY}' 2>/dev/null | base64 -d || true)
if [ -z "$Y_PROVIDER_API_KEY" ]; then
  Y_PROVIDER_API_KEY=$(openssl rand -hex 32)
  print_status "Generated Y_PROVIDER_API_KEY"
fi

# Create or update the docs-secrets secret
mt_apply kubectl apply -f <(kubectl create secret generic docs-secrets \
  --from-literal=DJANGO_SECRET_KEY="$DJANGO_SECRET_KEY" \
  --from-literal=DATABASE_PASSWORD="$DB_PASSWORD" \
  --from-literal=AWS_S3_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_S3_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=OIDC_RP_CLIENT_SECRET="${TF_VAR_oidc_rp_client_secret_docs:-$(kubectl -n "$NS_DOCS" get secret docs-secrets -o jsonpath='{.data.OIDC_RP_CLIENT_SECRET}' 2>/dev/null | base64 -d)}" \
  --from-literal=Y_PROVIDER_API_KEY="$Y_PROVIDER_API_KEY" \
  --from-literal=JWT_PRIVATE_KEY="$JWT_PRIVATE_KEY" \
  -n "$NS_DOCS" \
  --dry-run=client -o yaml)

# Collaboration server (yhub) secrets: its PostgreSQL url and its signing key.
# Its database lives next to the Docs one, same tenant role (the tenant user's
# password is DATABASE_PASSWORD above), created by docs-db-init below.
# Session pooling in PgBouncer (wildcard [databases] entry), so yhub's
# prepared statements work and no PgBouncer change is needed.
DOCS_YHUB_DB_NAME="${DOCS_DB_NAME:?DOCS_DB_NAME not set by config.sh}_yhub"
export DOCS_YHUB_DB_NAME
: "${TENANT_DB_USER:?TENANT_DB_USER not set by config.sh}" "${PG_HOST:?PG_HOST not set}"
YHUB_POSTGRES_URL="postgres://$(U="$TENANT_DB_USER" jq -rn 'env.U|@uri'):$(P="$DB_PASSWORD" jq -rn 'env.P|@uri')@${PG_HOST}:5432/${DOCS_YHUB_DB_NAME}"
mt_apply kubectl apply -f <(kubectl create secret generic docs-yhub \
  --from-literal=POSTGRES="$YHUB_POSTGRES_URL" \
  --from-literal=YHUB_JWT_PRIVATE_KEY="$YHUB_JWT_PRIVATE_KEY" \
  -n "$NS_DOCS" \
  --dry-run=client -o yaml)
unset YHUB_POSTGRES_URL JWT_PRIVATE_KEY YHUB_JWT_PRIVATE_KEY

print_success "Secrets configured successfully"

# Step 5: Deploy simple Redis service to tenant docs namespace
# Note: Redis for docs is tenant-specific for data isolation
print_status "Deploying Redis service for backend to namespace $NS_DOCS..."
mt_apply kubectl apply -f <(sed "s/namespace: docs/namespace: $NS_DOCS/g" "$REPO_ROOT/docs/redis-deployment.yaml")
mt_apply kubectl apply -f <(sed "s/namespace: docs/namespace: $NS_DOCS/g" "$REPO_ROOT/docs/redis-service.yaml")
poll_pod_ready "$NS_DOCS" "io.kompose.service=redis" 60 5 || true
print_success "Redis service deployed to namespace $NS_DOCS"

# The collaboration server's own Redis (noeviction; see docs/yhub-redis.yaml
# for why it cannot share the backend's allkeys-lru instance).
mt_apply kubectl apply -f <(sed "s/namespace: docs/namespace: $NS_DOCS/g" "$REPO_ROOT/docs/yhub-redis.yaml")

# Step 6: Apply Docs ConfigMaps (storage backends, docs-config,
# mt_settings/mt_patches, email assets)
print_status "Applying Docs manifests to namespace $NS_DOCS..."
print_status "Using environment: DOCS_HOST=$DOCS_HOST, AUTH_HOST=$AUTH_HOST"
print_status "Database user: $TENANT_DB_USER, Database: $DOCS_DB_NAME"

# Apply manifests with namespace substitution
mt_apply kubectl apply -f <(sed "s/namespace: docs/namespace: $NS_DOCS/g" "$REPO_ROOT/docs/storage-backends-configmap.yaml")
# save-status.js (keepalive on content PATCHes) is gone with impress 6:
# content is saved over the websocket, nothing PATCHes it any more.
kubectl -n "$NS_DOCS" delete configmap save-status-scripts --ignore-not-found
mt_apply kubectl apply -f <(envsubst < "$REPO_ROOT/docs/env-d-yprovider-configmap.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_DOCS/g")
: "${S3_ENDPOINT:?S3_ENDPOINT not set by config.sh}" "${S3_ADDRESSING_STYLE:?S3_ADDRESSING_STYLE not set by config.sh}" "${S3_USE_SSL:?S3_USE_SSL not set by config.sh}"
mt_apply kubectl apply -f <(envsubst < "$REPO_ROOT/docs/docs-config.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_DOCS/g")

# Python customizations ConfigMap: mt_settings.py (settings subclass selected by
# DJANGO_SETTINGS_MODULE=mt_settings in docs-config) and the mt_patches Django
# app (invitation-email links through the account portal guest landing). Both
# fail closed at import if the upstream image drifts, so a change here must
# restart the backend — hence mt_apply.
for f in docs/mt_settings.py docs/mt_patches/__init__.py docs/mt_patches/apps.py; do
  [ -f "$REPO_ROOT/$f" ] || { print_error "Missing $f (required by the docs backend)"; exit 1; }
done
mt_apply kubectl apply -f <(kubectl -n "$NS_DOCS" create configmap docs-mt-python \
  --from-file=mt_settings.py="$REPO_ROOT/docs/mt_settings.py" \
  --from-file=__init__.py="$REPO_ROOT/docs/mt_patches/__init__.py" \
  --from-file=apps.py="$REPO_ROOT/docs/mt_patches/apps.py" \
  --dry-run=client -o yaml)
# The pre-5.x text-patching ConfigMap is no longer mounted; drop it if present.
kubectl -n "$NS_DOCS" delete configmap docs-invitation-patch --ignore-not-found

# Email assets ConfigMap — logo served by the frontend at /email-assets/logo-email.png
# (referenced by DJANGO_EMAIL_LOGO_IMG in docs-config for invitation emails)
mt_apply kubectl apply -f <(kubectl -n "$NS_DOCS" create configmap docs-email-assets \
  --from-file=logo-email.png="$REPO_ROOT/docs/assets/logo-email.png" \
  --dry-run=client -o yaml)

# ---------------------------------------------------------------------------
# ORDER IS LOAD-BEARING: the schema is made current BEFORE the new backend
# image is applied.
#
# Applying the Deployment starts the rollout immediately, and the backend's
# readinessProbe is /__lbheartbeat__, which returns 200 without touching the
# database. So a new image applied ahead of its migrations goes into the
# Service endpoints speaking a schema the database does not have yet, and
# every login 500s until the migrations Job finishes. livenessProbe is
# /__heartbeat__, which checks connectivity rather than schema, so the pod
# stays green and never restarts out of that state; maxUnavailable: 0 means
# the old pods keep serving the old schema alongside it.
#
# Harmless while migrations were no-ops. The 4.4.0 -> 5.6.1 upgrade put six
# of them in that window, one adding a NOT NULL column. Do not move the
# backend apply back above this block.
#
# The move also made a second invariant load-bearing: the two Job applies
# below must stay PLAIN `kubectl apply`, never mt_apply. mt_delete_job_wait
# deletes then applies, so a Job always reports "created" and always diffs as
# a change. Here -- ahead of both mt_has_changes gates -- that would flag a
# change on every deploy and spuriously rollout-restart backend, frontend and
# y-provider every time. At the old position, after both gates, it would have
# been nearly harmless.
# ---------------------------------------------------------------------------
# Step 7: Initialize/verify database (idempotent)
# The db-init job runs in NS_DOCS (where docs-secrets is) and connects to PostgreSQL cross-namespace
print_status "Ensuring docs role/database exist and privileges set..."

# Copy postgres credentials to docs namespace so the db-init job can access them
print_status "Copying PostgreSQL credentials to docs namespace for db-init job..."
POSTGRES_PASSWORD=$(mt_pg_password)
if [ -z "$POSTGRES_PASSWORD" ]; then
    print_error "Could not get postgres-credentials secret from $NS_DB"
    exit 1
fi
kubectl create secret generic postgres-credentials \
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

mt_delete_job_wait "$NS_DOCS" docs-db-init || exit 1
envsubst '${DOCS_DB_NAME} ${DOCS_YHUB_DB_NAME} ${TENANT_DB_USER} ${PG_HOST} ${KEYCLOAK_DB_PASSWORD}' < "$REPO_ROOT/docs/db-init-job.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_DOCS/g" | kubectl apply -f -
if ! poll_job_complete "$NS_DOCS" "docs-db-init" 300 5; then
    print_error "Database initialization failed"
    exit 1
fi
print_success "Database role/database verified"

# NOTE: Database user passwords are managed on the external PG VM.
# No in-cluster password sync needed — PgBouncer uses auth_query.

# Step 8: Run database migrations
print_status "Running Django database migrations..."
mt_delete_job_wait "$NS_DOCS" docs-migrations || exit 1
cat "$REPO_ROOT/docs/migrations-job.yaml" | \
  sed "s/namespace: docs/namespace: $NS_DOCS/g" | \
  sed "s/docs-postgresql.docs.svc/${PG_SERVICE_NAME}.$NS_DB.svc/g" | \
  kubectl apply -f -
# Widened 300s→900s: a cold/contended dev cluster has stretched the Django
# app-import in this job to ~3.5min (CPU starvation during concurrent tenant
# deploys), and the job completed at ~520s — past the old 300s poll, which then
# failed the deploy while the migration was still running. 900s tolerates that.
if ! poll_job_complete "$NS_DOCS" "docs-migrations" 900 5; then
    print_error "Database migrations failed"
    exit 1
fi
print_success "Database migrations completed"

# Step 8a: Collaboration server schema (impress >= 6). Idempotent, every deploy:
# an image bump can add a table, and until it exists every document read fails.
# Plain kubectl apply after mt_delete_job_wait, like the two Jobs above.
print_status "Creating/upgrading the collaboration server (yhub) schema in $DOCS_YHUB_DB_NAME..."
mt_delete_job_wait "$NS_DOCS" docs-yhub-init-db || exit 1
sed "s/namespace: docs/namespace: $NS_DOCS/g" "$REPO_ROOT/docs/yhub-init-db-job.yaml" | kubectl apply -f -
if ! poll_job_complete "$NS_DOCS" "docs-yhub-init-db" 600 5; then
    print_error "yhub schema initialization failed"
    kubectl -n "$NS_DOCS" logs job/docs-yhub-init-db --tail=50 2>/dev/null || true
    exit 1
fi
print_success "yhub schema is current"

# Step 9: Apply the backend, frontend and ingress manifests
# Update backend deployment to reference PostgreSQL in db namespace
# Uses envsubst for replica count from tenant config
# No EXIT trap here: notify.sh owns EXIT (deploy completion message). On a
# failed deploy the file stays in $TMPDIR; it holds only secretKeyRef names.
BACKEND_MANIFEST=$(mktemp)
envsubst '${DOCS_BACKEND_MIN_REPLICAS} ${DOCS_GUNICORN_WORKERS}' < "$REPO_ROOT/docs/backend-deployment.yaml" | \
  sed "s/namespace: docs/namespace: $NS_DOCS/g" | \
  sed "s/docs-postgresql.docs.svc/${PG_SERVICE_NAME}.$NS_DB.svc/g" > "$BACKEND_MANIFEST"
# A devbox's S3 endpoint and its Stalwart submission host are HTTPS/STARTTLS
# names signed by the local CA. boto3 verifies TLS regardless of AWS_S3_VERIFY
# (AWS_CA_BUNDLE); Django's SMTP STARTTLS uses OpenSSL's default paths
# (SSL_CERT_DIR adds the CA without dropping the public roots).
if mt_is_local_edge; then
  print_status "edge local: backend trusts the local CA for S3 and SMTP (AWS_CA_BUNDLE, SSL_CERT_DIR)"
  # shellcheck source=../scripts/lib/local-ca.sh
  source "${REPO_ROOT}/scripts/lib/local-ca.sh"
  mt_local_ca_publish_configmap "$NS_DOCS"
  mt_local_ca_trust "$BACKEND_MANIFEST" backend AWS_CA_BUNDLE SSL_CERT_DIR
fi
# Celery worker (impress >= 6 queues the websocket re-checks of a revoked
# access, deletions in yhub and the mention / ask-for-access mails; nothing
# consumed them before). Derived from the backend manifest so it can never
# drift from the backend's env, secrets and mounts: same image, settings and
# mt_patches; its own labels (it must not match the backend Service selector),
# no ports, and the probes upstream's chart gives the worker (6.1.1: the worker
# touches a heartbeat file from its event loop and a ready file once it
# consumes from the broker, both in the /tmp emptyDir).
CELERY_MANIFEST=$(mktemp)
yq '
  .metadata.name = "docs-celery" |
  .metadata.labels = {"app.kubernetes.io/name": "docs", "app.kubernetes.io/component": "celery-worker", "app.kubernetes.io/part-of": "mother-tree"} |
  .spec.replicas = 1 |
  .spec.selector.matchLabels = {"app.kubernetes.io/name": "docs", "app.kubernetes.io/component": "celery-worker"} |
  .spec.template.metadata.labels = {"app.kubernetes.io/name": "docs", "app.kubernetes.io/component": "celery-worker"} |
  (.spec.template.spec.containers[] | select(.name == "backend")) |= (
    .name = "celery" |
    .args = ["exec celery -A impress.celery_app worker -l INFO -n impress@%h --concurrency 2"] |
    del(.ports) | del(.readinessProbe) |
    .startupProbe = {"exec": {"command": ["/bin/sh", "-c", "test -f /tmp/celery_worker_ready"]}, "periodSeconds": 5, "timeoutSeconds": 5, "failureThreshold": 60} |
    .livenessProbe = {"exec": {"command": ["/bin/sh", "-c", "f=/tmp/celery_worker_heartbeat; [ -f \"$f\" ] && age=$(( $(date +%s) - $(stat -c %Y \"$f\") )) && [ \"$age\" -ge 0 ] && [ \"$age\" -lt 120 ]"]}, "periodSeconds": 30, "timeoutSeconds": 5, "failureThreshold": 3} |
    .resources = {"requests": {"cpu": "50m", "memory": "256Mi"}, "limits": {"memory": "1Gi"}}
  )
' "$BACKEND_MANIFEST" > "$CELERY_MANIFEST"
[ "$(yq '.spec.template.spec.containers[] | select(.name == "celery") | .name' "$CELERY_MANIFEST")" = "celery" ] || {
  print_error "Could not derive the Celery worker manifest from the backend manifest"; exit 1; }

# ORDER (impress >= 6): backend first, then the collaboration server. yhub
# 6.1 reads a caller's rights from the backend's /documents/{id}/abilities/
# endpoint, which a 5.x backend answers 404 — read by yhub as a refusal.
mt_apply kubectl apply -f "$BACKEND_MANIFEST"
rm -f "$BACKEND_MANIFEST"
mt_apply kubectl apply -f <(sed "s/namespace: docs/namespace: $NS_DOCS/g" "$REPO_ROOT/docs/backend-service.yaml")
if ! kubectl -n "$NS_DOCS" rollout status deployment/backend --timeout=600s; then
  print_error "Docs backend rollout did not complete"
  exit 1
fi
mt_apply kubectl apply -f "$CELERY_MANIFEST"
rm -f "$CELERY_MANIFEST"

# Collaboration server (yhub) and its ingress. The ingress is applied once yhub
# is serving, replacing the y-provider's websocket ingress (impress < 6):
# /collaboration/ws/ now belongs to yhub.
print_status "Applying the collaboration server (yhub)..."
: "${S3_INTERNAL_ENDPOINT:?S3_INTERNAL_ENDPOINT not set by config.sh}" "${BUCKET_NAME:?BUCKET_NAME not set by config.sh}" "${S3_CLUSTER:?S3_CLUSTER not set by config.sh}"
# yhub refuses an endpoint with a path, and a trailing "/" reads as one.
YHUB_LEGACY_S3_ENDPOINT="${S3_INTERNAL_ENDPOINT%/}"
export YHUB_LEGACY_S3_ENDPOINT
YHUB_MANIFEST=$(mktemp)
envsubst '${DOCS_HOST} ${YPROVIDER_MIN_REPLICAS} ${YHUB_LEGACY_S3_ENDPOINT} ${S3_CLUSTER} ${BUCKET_NAME}' < "$REPO_ROOT/docs/yhub-deployment.yaml.tpl" | \
  sed "s/namespace: docs/namespace: $NS_DOCS/g" > "$YHUB_MANIFEST"
# A devbox's S3 gateway may be an HTTPS name signed by the local CA; node
# trusts extra roots through NODE_EXTRA_CA_CERTS.
if mt_is_local_edge && [[ "$S3_INTERNAL_ENDPOINT" == https://* ]]; then
  mt_local_ca_trust "$YHUB_MANIFEST" yhub NODE_EXTRA_CA_CERTS
fi
mt_apply kubectl apply -f "$YHUB_MANIFEST"
rm -f "$YHUB_MANIFEST"
if ! kubectl -n "$NS_DOCS" rollout status deployment/docs-yhub --timeout=600s; then
  print_error "Collaboration server (docs-yhub) rollout did not complete"
  kubectl -n "$NS_DOCS" logs deployment/docs-yhub --tail=50 2>/dev/null || true
  exit 1
fi
# Old ingress first: ingress-nginx's admission webhook refuses a second
# ingress claiming the same host + /collaboration/ws/ path.
kubectl -n "$NS_DOCS" delete ingress docs-yprovider --ignore-not-found
# Explicit variable list: a bare envsubst would blank nginx's $request_uri and
# silently disable the ingress's traversal filter.
mt_apply kubectl apply -f <(envsubst '${DOCS_HOST} ${TENANT_NAME}' < "$REPO_ROOT/docs/yhub-ingress.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_DOCS/g")
print_success "Collaboration server is serving"

# Deploy frontend with environment-specific configuration (includes replica count)
mt_apply kubectl apply -f <(envsubst < "$REPO_ROOT/docs/frontend-deployment.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_DOCS/g")
mt_apply kubectl apply -f <(sed "s/namespace: docs/namespace: $NS_DOCS/g" "$REPO_ROOT/docs/frontend-service.yaml")
mt_apply kubectl apply -f <(envsubst < "$REPO_ROOT/docs/ingress.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_DOCS/g")
# Static asset cache ingress (/_next/static/ with immutable cache headers)
mt_apply kubectl apply -f <(envsubst < "$REPO_ROOT/docs/static-cache-ingress.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_DOCS/g")
print_success "Docs manifests applied successfully to namespace $NS_DOCS"

# Step 10: Restart deployments to pick up ConfigMap changes, then wait for ready (PARALLEL)
if mt_has_changes; then
    print_status "Restarting backend, frontend, Celery worker and yhub to pick up ConfigMap/Secret changes..."
    kubectl -n "$NS_DOCS" rollout restart deployment/backend deployment/frontend deployment/docs-celery deployment/docs-yhub
    print_status "Waiting for Docs backend and frontend to be ready (parallel)..."
    # Wait for both in parallel
    kubectl -n "$NS_DOCS" rollout status deployment/backend --timeout=300s &
    BACKEND_PID=$!
    kubectl -n "$NS_DOCS" rollout status deployment/frontend --timeout=300s &
    FRONTEND_PID=$!
    kubectl -n "$NS_DOCS" rollout status deployment/docs-celery --timeout=300s &
    CELERY_PID=$!
    kubectl -n "$NS_DOCS" rollout status deployment/docs-yhub --timeout=300s &
    YHUB_PID=$!
    wait $BACKEND_PID $FRONTEND_PID $CELERY_PID $YHUB_PID
    print_success "Docs backend, frontend, Celery worker and yhub are ready"
else
    print_status "No config changes detected, skipping restart of deployment/backend deployment/frontend deployment/docs-celery deployment/docs-yhub"
fi

# Step 10a: Hand the legacy documents (impress < 6: {document-id}/file in the
# media bucket) to the collaboration server, and FAIL the deploy unless every
# document is accounted for. yhub's SOFT_MIGRATION only seeds a document when
# someone opens it; a document nobody opens stays in S3 until this backfill,
# and SOFT_MIGRATION must not be turned off before it has covered the corpus.
#
# `migrate_documents` is resumable and idempotent: it records what became of
# each document in impress_document_migration and skips the finished ones, so
# on later deploys it only hands over documents created since (answered
# "empty": they never had legacy content). It exits 0 even when documents
# fail, hence the ledger check after it. Derived from the migrations Job
# (same image, settings, mounts and env) plus the backend's signing key: the
# command calls yhub's /collaboration/migrate/ with an admin JWT, in-cluster
# (YHUB_API_BASE_URL).
print_status "Backfilling legacy documents into the collaboration server..."
read -r -d '' _MIGRATE_DOCUMENTS_SH <<'MIGRATE_EOF' || true
set -eu
python manage.py migrate_documents --retry-failed --concurrency 2
python manage.py shell -c '
from collections import Counter
from django.core.files.storage import default_storage
from core import models as m
S = m.DocumentMigrationStatus
done = {S.MIGRATED.value, S.ALREADY.value, S.EMPTY.value, S.NOTHING.value}
rows = list(m.Document.objects.values_list("id", "migration__status", "migration__error"))
ledger = Counter(status for _, status, _ in rows)
print("[migrate-documents] ledger:", {str(k): v for k, v in ledger.items()})
problems = [f"{doc_id} status={status} error={(error or chr(45))[:200]}"
            for doc_id, status, error in rows if status not in done]
# "empty" means yhub found no legacy object. A misconfigured legacy read that
# came back as NoSuchKey would look exactly the same, so confirm it against
# the bucket with the backend own storage: a legacy snapshot that exists
# while the ledger says empty means its content was never handed over.
for doc_id, status, _ in rows:
    if status == S.EMPTY.value and default_storage.exists(f"{doc_id}/file"):
        problems.append(f"{doc_id} status=empty but its legacy snapshot {doc_id}/file exists")
for doc_id, status, _ in rows:
    if status == S.NOTHING.value:
        print(f"[migrate-documents] WARNING: {doc_id}: no readable legacy version (status nothing)")
if problems:
    for line in problems:
        print("[migrate-documents] NOT MIGRATED:", line)
    raise SystemExit(f"[migrate-documents] {len(problems)} document(s) not migrated")
print("[migrate-documents] every document is accounted for")
'
MIGRATE_EOF
MIGRATE_DOCS_MANIFEST=$(mktemp)
sed "s/namespace: docs/namespace: $NS_DOCS/g" "$REPO_ROOT/docs/migrations-job.yaml" | \
  sed "s/docs-postgresql.docs.svc/${PG_SERVICE_NAME}.$NS_DB.svc/g" | \
  SCRIPT="$_MIGRATE_DOCUMENTS_SH" yq '
    .metadata.name = "docs-migrate-documents" |
    .spec.backoffLimit = 0 |
    (.spec.template.spec.containers[] | select(.name == "backend")) |= (
      .command = ["/bin/sh", "-c", strenv(SCRIPT)] |
      .env += [{"name": "JWT_PRIVATE_KEY_FILE", "value": "/etc/docs-jwt/backend-jwt.pem"}] |
      .volumeMounts += [{"name": "docs-jwt", "mountPath": "/etc/docs-jwt", "readOnly": true}]
    ) |
    .spec.template.spec.securityContext.fsGroup = 127 |
    .spec.template.spec.volumes += [{"name": "docs-jwt", "secret": {"secretName": "docs-secrets", "items": [{"key": "JWT_PRIVATE_KEY", "path": "backend-jwt.pem"}], "defaultMode": 288}}]
  ' > "$MIGRATE_DOCS_MANIFEST"
mt_delete_job_wait "$NS_DOCS" docs-migrate-documents || exit 1
kubectl apply -f "$MIGRATE_DOCS_MANIFEST"
rm -f "$MIGRATE_DOCS_MANIFEST"
if ! poll_job_complete "$NS_DOCS" "docs-migrate-documents" 900 5; then
    print_error "Legacy document backfill failed or left documents unmigrated"
    kubectl -n "$NS_DOCS" logs job/docs-migrate-documents --tail=40 2>/dev/null || true
    exit 1
fi
kubectl -n "$NS_DOCS" logs job/docs-migrate-documents --tail=5 2>/dev/null | grep '\[migrate-documents\]' || true
print_success "Every document is in the collaboration server"

# Step 11: Deploy/Update y-provider (declarative)
print_status "Applying y-provider deployment and service to namespace $NS_DOCS..."
mt_apply kubectl apply -f <(sed "s/namespace: docs/namespace: $NS_DOCS/g" "$REPO_ROOT/docs/health-sidecar-configmap.yaml")
# Uses envsubst for replica count from tenant config
mt_apply kubectl apply -f <(envsubst '${YPROVIDER_MIN_REPLICAS}' < "$REPO_ROOT/docs/y-provider-deployment.yaml" | sed "s/namespace: docs/namespace: $NS_DOCS/g")
mt_apply kubectl apply -f <(sed "s/namespace: docs/namespace: $NS_DOCS/g" "$REPO_ROOT/docs/y-provider-service.yaml")
# Restart to ensure ConfigMap changes are picked up (wait in background, check later)
if mt_has_changes; then
    # Brief pause to avoid "restart already triggered within past second" race with backend/frontend restart
    sleep 2
    kubectl -n "$NS_DOCS" rollout restart deploy/docs-y-provider
    kubectl -n "$NS_DOCS" rollout status deploy/docs-y-provider --timeout=300s &
    YPROVIDER_PID=$!
    # Wait for y-provider rollout to complete
    wait $YPROVIDER_PID
else
    print_status "No config changes detected, skipping restart of deploy/docs-y-provider"
fi
# Quick sanity: short endpoint check (non-fatal; kube liveness covers steady state)
print_status "Checking y-provider service endpoints..."
if kubectl -n "$NS_DOCS" get endpoints y-provider -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -qE '[0-9]'; then
  kubectl -n "$NS_DOCS" get endpoints y-provider
else
  print_warning "y-provider endpoints not yet reported; rely on rollout status/liveness"
fi
print_success "y-provider applied successfully"

# Step 11a: Deploy HorizontalPodAutoscalers (HPA) for auto-scaling (only if min != max replicas)
if [ "$DOCS_BACKEND_MIN_REPLICAS" != "$DOCS_BACKEND_MAX_REPLICAS" ]; then
  print_status "Deploying HPAs for docs backend, frontend, and y-provider..."
  envsubst < "$REPO_ROOT/docs/backend-hpa.yaml.tpl" | kubectl apply -f -
  envsubst < "$REPO_ROOT/docs/frontend-hpa.yaml.tpl" | kubectl apply -f -
  envsubst < "$REPO_ROOT/docs/yprovider-hpa.yaml.tpl" | kubectl apply -f -
  print_success "Docs HPAs deployed (CPU 80% threshold)"
else
  kubectl delete hpa backend-hpa -n "$NS_DOCS" --ignore-not-found >/dev/null 2>&1
  kubectl delete hpa frontend-hpa -n "$NS_DOCS" --ignore-not-found >/dev/null 2>&1
  kubectl delete hpa yprovider-hpa -n "$NS_DOCS" --ignore-not-found >/dev/null 2>&1
  print_status "Docs: fixed replicas, HPAs removed"
fi

# Step 11b: Deploy Grafana dashboard for Docs monitoring
print_status "Deploying Docs Grafana dashboard..."
cat "$REPO_ROOT/apps/manifests/docs/docs-dashboard-configmap.yaml" | sed "s/namespace: monitoring/namespace: $NS_MONITORING/g" | kubectl apply -f -
print_success "Docs Grafana dashboard deployed"


# Email link base URL is DJANGO_EMAIL_URL_APP in docs-config (impress >= 4.5);
# the django.contrib.sites row is no longer consulted, so no Site domain hack.

# Step 12: Keycloak realm import is done in create_env script after Keycloak is deployed
# (Keycloak is deployed via helmfile in create_env, after deploy-docs.sh completes)
print_status "Skipping Keycloak realm import (done in create_env after Keycloak deployment)"

# Step 13: Create superuser (skipped if manifest not present)
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

# Step 14: Verify deployment
print_status "Verifying Docs deployment..."

# Show resource snapshot
echo ""
echo "Resources in database namespace ($NS_DB):"
kubectl get deploy,svc -n "$NS_DB"
echo ""
echo "Resources in docs namespace ($NS_DOCS):"
kubectl get deploy,svc,ingress -n "$NS_DOCS"

# Step 15: Display access information
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
