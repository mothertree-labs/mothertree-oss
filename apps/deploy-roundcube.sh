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

# Track config changes to avoid restarting pods unnecessarily
mt_reset_change_tracker

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
print_status "Files host (calendar): $FILES_HOST"
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

# Copy PostgreSQL credentials to webmail namespace
print_status "Copying PostgreSQL credentials to $NS_WEBMAIL namespace..."
PG_PASSWORD=$(mt_pg_password)
if [ -z "$PG_PASSWORD" ]; then
    print_error "Could not retrieve postgres-credentials secret from $NS_DB namespace"
    exit 1
fi

mt_apply kubectl apply -f <(kubectl create secret generic postgres-credentials \
    --namespace="$NS_WEBMAIL" \
    --from-literal=postgres-password="$PG_PASSWORD" \
    --dry-run=client -o yaml)
print_success "PostgreSQL credentials copied"

# Apply Roundcube secrets first (needed by db-init job)
print_status "Applying Roundcube secrets..."
mt_apply kubectl apply -f - <<EOF
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
mt_apply kubectl apply -f <(envsubst '${NS_WEBMAIL} ${NS_MAIL} ${AUTH_HOST} ${KEYCLOAK_REALM} ${KEYCLOAK_INTERNAL_URL} ${ROUNDCUBE_DES_KEY} ${TENANT_DISPLAY_NAME} ${ROUNDCUBE_DB_USER} ${ROUNDCUBE_DB_NAME} ${TENANT_NAME} ${ROUNDCUBE_OIDC_SECRET} ${ROUNDCUBE_DB_PASSWORD} ${ROUNDCUBE_MEMORY_REQUEST} ${ROUNDCUBE_MEMORY_LIMIT} ${ROUNDCUBE_CPU_REQUEST} ${CONFIG_CHECKSUM} ${FILES_HOST} ${ROUNDCUBE_MIN_REPLICAS} ${PG_HOST} ${ROUNDCUBE_IMAGE}' \
    < "$REPO_ROOT/apps/manifests/roundcube/roundcube.yaml.tpl")
print_success "Roundcube Deployment and Service applied"

# Deploy HorizontalPodAutoscaler (HPA) for auto-scaling (only if min != max replicas)
if [ "$ROUNDCUBE_MIN_REPLICAS" != "$ROUNDCUBE_MAX_REPLICAS" ]; then
  print_status "Deploying HPA for Roundcube..."
  envsubst < "$REPO_ROOT/apps/manifests/roundcube/roundcube-hpa.yaml.tpl" | kubectl apply -f -
  print_success "Roundcube HPA deployed (CPU 80% threshold)"
else
  kubectl delete hpa roundcube-hpa -n "$NS_WEBMAIL" --ignore-not-found >/dev/null 2>&1
  print_status "Roundcube: fixed replicas ($ROUNDCUBE_MIN_REPLICAS), HPA removed"
fi

# Apply ingress for webmail
mt_apply kubectl apply -f <(envsubst < "$REPO_ROOT/apps/manifests/roundcube/ingress.yaml.tpl")
print_success "Ingress applied for $WEBMAIL_HOST"

# Restart deployment to pick up config changes
mt_restart_if_changed deployment/roundcube -n "$NS_WEBMAIL"

# Wait for a RUNNING Roundcube pod — NOT Ready. The rc-readiness probe fails with
# SQLSTATE 42P01 (undefined_table) while the schema is missing, so gating on Ready
# here DEADLOCKS: the pod can't go Ready until the schema exists, but the schema
# repair below needs a Running pod to exec into. So wait for Running, repair the
# schema, THEN wait for Ready (moved below the gate). A genuinely broken image
# (ImagePull/crash-before-Running) never reaches Running and still fails fast here.
# Unconditional (not gated on mt_has_changes) because the schema gate below is too.
print_status "Waiting for a Running Roundcube pod (schema repair precedes the readiness gate)..."
_rc_running=""
for _rc_try in $(seq 1 36); do
    _rc_running=$(kubectl get pod -n "$NS_WEBMAIL" -l app=roundcube \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')
    [ -n "$_rc_running" ] && break
    sleep 5
done
if [ -z "$_rc_running" ]; then
    print_error "No Running Roundcube pod within 180s"
    echo ""
    print_error "=== Diagnostic dump ==="
    set +e
    dump_pod_diagnostics "$NS_WEBMAIL" "app=roundcube"
    echo ""
    print_error "Diagnostics: roundcube pod logs (current, last 200 lines)"
    kubectl logs -n "$NS_WEBMAIL" -l app=roundcube --tail=200 --all-containers=true || true
    echo ""
    print_error "Diagnostics: roundcube pod logs (previous, last 200 lines — if CrashLoop)"
    kubectl logs -n "$NS_WEBMAIL" -l app=roundcube --previous --tail=200 --all-containers=true 2>/dev/null || \
        echo "  (no previous container — pod did not restart)"
    exit 1
fi
print_success "Roundcube pod is Running ($_rc_running)"

# =============================================================================
# Schema-initialization gate (UNCONDITIONAL — runs on every deploy)
# =============================================================================
# The roundcube image entrypoint runs `bin/initdb.sh --update` exactly once at
# container start and SWALLOWS its failure (`|| echo "Failed to initialize the
# database..."`), then starts Apache anyway. If the Postgres DB was unreachable
# at that single instant — e.g. PgBouncer was still serving a cached
# `database "roundcube_<tenant>" does not exist` negative entry from a dev
# drop/recreate window — the schema is never built and never retried. Every
# request then fails `relation "session" does not exist`, so Roundcube cannot
# persist the OIDC session and webmail login hangs at the inbox. The rc-readiness
# probe (roundcube.yaml.tpl) returns NotReady on exactly this SQLSTATE 42P01, so a
# schema-less pod never goes Ready — which is why this repair MUST run before the
# Ready gate: a Running pod is enough to exec bin/initdb.sh into, but a Ready gate
# before the repair would deadlock. See memory project_shard5_10_roundcube_login_root_cause.
#
# This gate is UNCONDITIONAL — deliberately OUTSIDE the `if mt_has_changes` block
# above. The DB can be left empty independent of any manifest change: when config
# is unchanged, mt_restart_if_changed does NOT restart the pod, so the entrypoint
# never re-runs initdb, and the per-request PHP app keeps hitting the empty DB
# with no restart to heal it. So we must verify on EVERY deploy.
print_status "Verifying Roundcube DB schema is initialized..."

# The Running-pod wait above already ensured a pod we can exec into / query.
# We deliberately do NOT wait for Ready here: the rc-readiness probe 42P01's on an
# empty schema, so the Ready gate must come AFTER this repair (moved below).

# Returns 0 iff the canonical "schema initialized" marker (system.roundcube-version)
# is present AND reachable over the SAME path the app uses: as the roundcube DB
# user, through PgBouncer, into the tenant DB. A throwaway psql pod keeps this
# independent of whether the roundcube image ships a psql client.
#
# Retries up to 3x: a transient throwaway-pod scheduling/PgBouncer hiccup returns
# empty just like a genuinely-missing schema, so without retries a flaky query
# could masquerade as "schema missing" and spuriously fail an otherwise-healthy
# deploy. Returns 0 as soon as a version is read; only concludes "missing" after
# all attempts come back empty. On a healthy DB the first attempt succeeds (no
# added latency); the cost is paid only on the missing/transient path.
_rc_schema_ok() {
    local _out _attempt
    for _attempt in 1 2 3; do
        _out=$(kubectl run "rc-schema-verify-$$-${RANDOM}" --rm -i --restart=Never \
            --image=postgres:15-alpine --quiet -n "$NS_WEBMAIL" --pod-running-timeout=120s \
            --env "PGHOST=$PG_HOST" --env "PGUSER=$ROUNDCUBE_DB_USER" \
            --env "PGPASSWORD=$ROUNDCUBE_DB_PASSWORD" --env "PGDATABASE=$ROUNDCUBE_DB_NAME" \
            -- psql -tAc "SELECT value FROM system WHERE name='roundcube-version';" 2>/dev/null || true)
        [ -n "$(printf '%s' "$_out" | tr -d '[:space:]')" ] && return 0
        [ "$_attempt" -lt 3 ] && sleep $((_attempt * 5))
    done
    return 1
}

if _rc_schema_ok; then
    print_success "Roundcube DB schema present (system.roundcube-version set) — OK"
else
    # Schema missing: the entrypoint's one-shot initdb was swallowed. Re-run the
    # SAME idempotent command in the live pod — by now the DB is reachable
    # (PgBouncer's ~15s negative-cache TTL has long expired since db-init created
    # the DB), so this builds the schema. No-op on an already-initialized DB.
    print_warning "Roundcube DB schema MISSING — entrypoint initdb was swallowed; repairing in-pod"
    RC_POD=$(kubectl get pod -n "$NS_WEBMAIL" -l app=roundcube \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')
    if [ -z "$RC_POD" ]; then
        print_error "No Running Roundcube pod found — cannot repair DB schema"
        set +e
        dump_pod_diagnostics "$NS_WEBMAIL" "app=roundcube"
        exit 1
    fi
    print_status "Running bin/initdb.sh --update in pod $RC_POD..."
    set +e
    RC_INITDB_OUT=$(kubectl exec -n "$NS_WEBMAIL" "$RC_POD" -c roundcube -- \
        bash -c 'cd /var/www/html && bin/initdb.sh --dir=/var/www/html/SQL --update' 2>&1)
    RC_INITDB_RC=$?
    set -e
    printf '%s\n' "$RC_INITDB_OUT" | sed 's/^/    /'
    [ "$RC_INITDB_RC" -ne 0 ] && print_warning "initdb.sh exited $RC_INITDB_RC (verifying schema regardless)"

    if _rc_schema_ok; then
        print_success "Roundcube DB schema repaired and verified (system.roundcube-version set)"
    else
        # Fail loudly per CLAUDE.md — a schema-less Roundcube means webmail OIDC
        # login hangs; never report a broken deploy as success.
        print_error "Roundcube DB schema STILL missing after initdb — webmail OIDC login would hang"
        print_error "(relation \"session\" does not exist family — see memory project_shard5_10_roundcube_login_root_cause)"
        echo ""
        print_error "=== bin/initdb.sh output ==="
        printf '%s\n' "$RC_INITDB_OUT" | sed 's/^/    /'
        echo ""
        set +e
        dump_pod_diagnostics "$NS_WEBMAIL" "app=roundcube"
        exit 1
    fi
fi

# Schema is present now → the rc-readiness probe (which 42P01's on an empty schema)
# can pass. Wait for the rollout to reach Ready. This is the fail-fast gate that
# used to run BEFORE the repair and deadlocked on a dropped/empty DB; moved here so
# it still catches a genuinely broken image (crashloop on a non-schema fault) but
# only after the DB is healed. Idempotent if already rolled out.
print_status "Waiting for Roundcube Deployment to be Ready..."
if kubectl rollout status deployment/roundcube -n "$NS_WEBMAIL" --timeout=180s; then
    print_success "Roundcube Deployment is Ready"
else
    print_error "Roundcube Deployment did not become Ready within 180s"
    echo ""
    print_error "=== Diagnostic dump ==="
    set +e
    dump_pod_diagnostics "$NS_WEBMAIL" "app=roundcube"
    echo ""
    print_error "Diagnostics: roundcube pod logs (current, last 200 lines)"
    kubectl logs -n "$NS_WEBMAIL" -l app=roundcube --tail=200 --all-containers=true || true
    echo ""
    print_error "Diagnostics: roundcube pod logs (previous, last 200 lines — if CrashLoop)"
    kubectl logs -n "$NS_WEBMAIL" -l app=roundcube --previous --tail=200 --all-containers=true 2>/dev/null || \
        echo "  (no previous container — pod did not restart)"
    exit 1
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
