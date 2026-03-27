#!/bin/bash

# Deploy Nextcloud to Kubernetes
# This script handles the complete deployment of Nextcloud for file management
#
# Namespace structure:
#   - PostgreSQL in NS_DB (shared 'db' namespace)
#   - Nextcloud in NS_FILES (tenant-prefixed namespace, e.g., 'tn-example-files')
#
# Architecture: Nextcloud uses emptyDir (no PVC) with identity values persisted
# in a K8s Secret. The seed-identity init container populates the emptyDir on
# every pod start, enabling RollingUpdate deploys with zero downtime.
#
# Usage:
#   ./apps/deploy-nextcloud.sh -e dev -t example

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy Nextcloud for a tenant."
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
mt_deploy_start "deploy-nextcloud"

mt_require_commands kubectl helm envsubst openssl

# Helper: get a running, non-terminating, Ready Nextcloud pod name.
# During rolling updates or HPA scale-up, not-yet-ready pods may appear in the
# pod list.  Picking one causes "container not found" errors because the
# nextcloud container hasn't passed readiness yet.  This helper prefers a Ready
# pod, falling back to any non-terminating pod if none are Ready yet.
_get_nc_pod() {
    local pods
    pods=$(kubectl get pod -n "$NS_FILES" -l app.kubernetes.io/instance=nextcloud \
        -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"|"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    # Prefer Ready pods (no deletionTimestamp, Ready=True)
    local ready_pod
    ready_pod=$(echo "$pods" | grep '^|True|' | head -1 | cut -d'|' -f3)
    if [ -n "$ready_pod" ]; then
        echo "$ready_pod"
        return
    fi
    # Fall back to any non-terminating pod
    echo "$pods" | grep '^|' | head -1 | cut -d'|' -f3 || true
}

# Helper: run an occ command with automatic retry on "require upgrade" errors.
# With HPA ≥2 replicas, another pod's before-starting hook can run occ upgrade
# between our individual theming commands, flipping the DB into "require upgrade"
# state.  This wrapper detects that and re-runs occ upgrade before retrying.
_nc_occ_retry() {
    local pod="$1"
    shift
    local cmd="$*"
    local max_retries=3
    for attempt in $(seq 1 "$max_retries"); do
        local output
        output=$(kubectl exec -n "$NS_FILES" "$pod" -c nextcloud -- \
            su -s /bin/sh www-data -c "$cmd" 2>&1) && {
            [ -n "$output" ] && echo "$output"
            return 0
        }
        if echo "$output" | grep -qi "require upgrade"; then
            print_warning "require upgrade detected (attempt $attempt/$max_retries), reconciling..."
            kubectl exec -n "$NS_FILES" "$pod" -c nextcloud -- \
                su -s /bin/sh www-data -c 'php occ upgrade --no-interaction' 2>/dev/null || true
            sleep 2
        else
            # Non-upgrade error — don't retry
            echo "$output"
            return 1
        fi
    done
    print_error "occ command failed after $max_retries retries: $cmd"
    return 1
}

print_status "Starting Nextcloud deployment for environment: $MT_ENV"
print_status "Database namespace: $NS_DB"
print_status "Files namespace: $NS_FILES"
print_status "Using environment: FILES_HOST=$FILES_HOST, AUTH_HOST=$AUTH_HOST"
print_status "Database user: $TENANT_DB_USER, Database: $NEXTCLOUD_DB_NAME"

# Verify PG_HOST is set (detected by config.sh)
if [ -z "${PG_HOST:-}" ]; then
    print_error "PostgreSQL not found in $NS_DB namespace and PG_HOST not set."
    print_error "Either set PG_HOST or run 'deploy_infra $MT_ENV' first."
    exit 1
fi
print_status "Using PostgreSQL: $PG_HOST"

# Get OIDC client secret
NEXTCLOUD_OIDC_SECRET="${TF_VAR_nextcloud_oidc_client_secret:-}"
if [ -z "$NEXTCLOUD_OIDC_SECRET" ]; then
    print_error "NEXTCLOUD_OIDC_CLIENT_SECRET not set. Add nextcloud_client_secret to tenant secrets."
    exit 1
fi
print_success "OIDC client secret retrieved"

# Step 1: Create files namespace if it doesn't exist
print_status "Ensuring files namespace exists..."
if ! kubectl get namespace "$NS_FILES" >/dev/null 2>&1; then
    kubectl create namespace "$NS_FILES"
    print_success "Created files namespace: $NS_FILES"
else
    print_status "Files namespace $NS_FILES already exists"
fi

# Step 2: Wait for PgBouncer to be ready (sole entrypoint to external PG VM)
print_status "Waiting for PgBouncer to be ready in namespace $NS_DB..."
if ! poll_pod_ready "$NS_DB" "app=pgbouncer" 300 5; then
    print_error "PgBouncer is not ready"
    exit 1
fi

# Step 3: Create Nextcloud database secret using the CORRECT password source
# IMPORTANT: The authoritative password for the tenant's DB user is in docs-secrets.DATABASE_PASSWORD
print_status "Creating Nextcloud database secret..."
DB_PASSWORD=$(kubectl get secret docs-secrets -n "$NS_DOCS" -o jsonpath='{.data.DATABASE_PASSWORD}' | base64 -d 2>/dev/null || echo "")
if [ -z "$DB_PASSWORD" ]; then
    print_error "Failed to retrieve PostgreSQL password from docs-secrets secret in namespace $NS_DOCS"
    exit 1
fi

kubectl create secret generic nextcloud-db \
    --namespace "$NS_FILES" \
    --from-literal=db-username="$TENANT_DB_USER" \
    --from-literal=db-password="$DB_PASSWORD" \
    --from-literal=db-hostname="$PG_HOST" \
    --from-literal=db-database="$NEXTCLOUD_DB_NAME" \
    --dry-run=client -o yaml | kubectl apply -f -
print_success "Nextcloud database secret created/updated (user: $TENANT_DB_USER)"

# Step 4: Create Nextcloud OIDC secret
print_status "Creating Nextcloud OIDC secret..."
kubectl create secret generic nextcloud-oidc \
    --namespace "$NS_FILES" \
    --from-literal=oidc-client-id=nextcloud-app \
    --from-literal=oidc-client-secret="$NEXTCLOUD_OIDC_SECRET" \
    --from-literal=oidc-provider-url="https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}" \
    --dry-run=client -o yaml | kubectl apply -f -
print_success "Nextcloud OIDC secret created/updated"

# Step 4b: Create Nextcloud S3 secret for object storage
print_status "Creating Nextcloud S3 secret..."
S3_ACCESS_KEY="${TF_VAR_files_s3_access_key:-}"
S3_SECRET_KEY="${TF_VAR_files_s3_secret_key:-}"

if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
    print_warning "S3 credentials not set (TF_VAR_files_s3_access_key/TF_VAR_files_s3_secret_key)"
    print_warning "Nextcloud will not be able to use S3 object storage"
else
    kubectl create secret generic nextcloud-s3-credentials \
        --namespace "$NS_FILES" \
        --from-literal=access_key="$S3_ACCESS_KEY" \
        --from-literal=secret_key="$S3_SECRET_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    print_success "Nextcloud S3 secret created/updated"
fi

# Step 4b.1: Create Nextcloud Google Integration secret (for Drive import)
if [ "${GOOGLE_IMPORT_ENABLED:-false}" = "true" ]; then
    print_status "Creating Nextcloud Google Integration secret..."
    if [ -z "${GOOGLE_CLIENT_ID:-}" ] || [ -z "${GOOGLE_CLIENT_SECRET:-}" ]; then
        print_warning "Google credentials not set (google.client_id/client_secret in secrets)"
        print_warning "Google Drive import will not work until credentials are configured"
    else
        kubectl create secret generic nextcloud-google \
            --namespace "$NS_FILES" \
            --from-literal=google-client-id="$GOOGLE_CLIENT_ID" \
            --from-literal=google-client-secret="$GOOGLE_CLIENT_SECRET" \
            --dry-run=client -o yaml | kubectl apply -f -
        print_success "Nextcloud Google Integration secret created/updated"
    fi
fi

# Step 4c: Deploy Redis for Nextcloud file locking and distributed caching
print_status "Deploying Redis for Nextcloud caching and file locking..."

# Generate or reuse Redis password
EXISTING_REDIS_PASS=$(kubectl get secret nextcloud-redis -n "$NS_FILES" -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d || echo "")
if [ -n "$EXISTING_REDIS_PASS" ]; then
    REDIS_PASSWORD="$EXISTING_REDIS_PASS"
    print_status "Reusing existing Redis password from nextcloud-redis secret"
else
    REDIS_PASSWORD=$(openssl rand -hex 24)
    print_status "Generated new Redis password"
fi

kubectl create secret generic nextcloud-redis \
    --namespace "$NS_FILES" \
    --from-literal=redis-password="$REDIS_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
print_success "Redis secret created/updated in $NS_FILES"

# Apply Redis deployment and service
kubectl apply -n "$NS_FILES" -f "$REPO_ROOT/apps/manifests/nextcloud/redis.yaml"

# Wait for Redis to be ready
if ! poll_pod_ready "$NS_FILES" "app=redis" 60 5; then
    print_warning "Redis not ready yet, but continuing (Nextcloud will retry connection)"
fi
print_success "Redis deployed to $NS_FILES"

# Step 5: Run Nextcloud database initialization job (in files namespace where secrets are accessible)
print_status "Running Nextcloud database initialization..."

# Copy postgres credentials to files namespace so the db-init job can access them
print_status "Copying PostgreSQL credentials to files namespace for db-init job..."
POSTGRES_PASSWORD=$(mt_pg_password)
if [ -z "$POSTGRES_PASSWORD" ]; then
    print_error "Could not get postgres-credentials secret from $NS_DB"
    exit 1
fi
kubectl create secret generic postgres-credentials \
    --from-literal=postgres-password="$POSTGRES_PASSWORD" \
    -n "$NS_FILES" \
    --dry-run=client -o yaml | kubectl apply -f -

# Copy docs-secrets from NS_DOCS to NS_FILES for the DATABASE_PASSWORD
print_status "Copying docs-secrets to files namespace..."
DOCS_DB_PASSWORD=$(kubectl get secret docs-secrets -n "$NS_DOCS" -o jsonpath='{.data.DATABASE_PASSWORD}' | base64 -d 2>/dev/null || echo "")
if [ -z "$DOCS_DB_PASSWORD" ]; then
    print_error "Could not get DATABASE_PASSWORD from docs-secrets in $NS_DOCS"
    exit 1
fi
kubectl create secret generic docs-secrets \
    --from-literal=DATABASE_PASSWORD="$DOCS_DB_PASSWORD" \
    -n "$NS_FILES" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS_FILES" delete job/nextcloud-db-init --ignore-not-found=true || true
envsubst '${NEXTCLOUD_DB_NAME} ${TENANT_DB_USER} ${PG_HOST}' < "$REPO_ROOT/docs/nextcloud-db-init-job.yaml.tpl" | sed "s/namespace: docs/namespace: $NS_FILES/g" | kubectl apply -f -
if ! poll_job_complete "$NS_FILES" "nextcloud-db-init" 180 5; then
    print_error "Nextcloud database initialization failed"
    exit 1
fi
print_success "Nextcloud database initialized"

# Step 5b: Update PostgreSQL table statistics (ANALYZE)
# Autoanalyze only triggers after enough row modifications (50 + 10% of rows).
# Tables like oc_preferences and oc_mimetypes are bulk-loaded once and barely
# change, so autoanalyze never fires and the planner uses stale stats from
# table creation — causing full sequential scans on every request.
print_status "Updating PostgreSQL table statistics (ANALYZE)..."
echo "ANALYZE;" | mt_psql -d "$NEXTCLOUD_DB_NAME" \
    && print_success "ANALYZE completed for $NEXTCLOUD_DB_NAME" \
    || print_warning "ANALYZE failed (non-critical, will retry on next deploy)"

# Step 5c: Auto-migration from PVC to emptyDir
# If a PVC exists but the identity secret doesn't, extract identity values from the running pod
# before switching to emptyDir (so the identity is preserved across the migration).
IDENTITY_SECRET_EXISTS=$(kubectl get secret nextcloud-identity -n "$NS_FILES" -o name 2>/dev/null || true)
PVC_EXISTS=$(kubectl get pvc nextcloud-nextcloud -n "$NS_FILES" -o name 2>/dev/null || true)
if [ -n "$PVC_EXISTS" ] && [ -z "$IDENTITY_SECRET_EXISTS" ]; then
    print_status "PVC migration: PVC exists but identity secret doesn't — extracting identity from running pod..."
    NEXTCLOUD_POD=$(_get_nc_pod)
    if [ -n "$NEXTCLOUD_POD" ]; then
        if timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- test -f /var/www/html/config/config.php 2>/dev/null; then
            # Extract identity values from config.php using PHP for accurate parsing
            # (grep is unreliable — e.g. 'secret' key also appears inside objectstore.arguments)
            MIGRATE_INSTANCE_ID=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
                php -r 'include "/var/www/html/config/config.php"; echo $CONFIG["instanceid"] ?? "";' 2>/dev/null || true)
            MIGRATE_PASSWORD_SALT=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
                php -r 'include "/var/www/html/config/config.php"; echo $CONFIG["passwordsalt"] ?? "";' 2>/dev/null || true)
            MIGRATE_SECRET=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
                php -r 'include "/var/www/html/config/config.php"; echo $CONFIG["secret"] ?? "";' 2>/dev/null || true)
            # Get installed version from version.php
            MIGRATE_VERSION=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
                php -r 'require "/var/www/html/version.php"; echo implode(".", $OC_Version);' 2>/dev/null || true)

            if [ -n "$MIGRATE_INSTANCE_ID" ] && [ -n "$MIGRATE_PASSWORD_SALT" ] && [ -n "$MIGRATE_SECRET" ]; then
                kubectl create secret generic nextcloud-identity \
                    --namespace "$NS_FILES" \
                    --from-literal=instanceid="$MIGRATE_INSTANCE_ID" \
                    --from-literal=passwordsalt="$MIGRATE_PASSWORD_SALT" \
                    --from-literal=secret="$MIGRATE_SECRET" \
                    --from-literal=version="${MIGRATE_VERSION:-unknown}" \
                    --from-literal=trusted-domains="localhost ${FILES_HOST} ${CALENDAR_HOST:-} nextcloud.${NS_FILES}.svc.cluster.local" \
                    --dry-run=client -o yaml | kubectl apply -f -
                print_success "PVC migration: Identity secret created from running pod"
            else
                print_warning "PVC migration: Could not extract all identity values (instanceid=$MIGRATE_INSTANCE_ID)"
                print_warning "PVC migration: First install with emptyDir will create new identity"
            fi
        else
            print_warning "PVC migration: No config.php found in running pod"
        fi
    else
        print_warning "PVC migration: No running Nextcloud pod found — identity will be created on first install"
    fi
fi

# Step 5d: Apply identity-init ConfigMap (the init container script)
print_status "Applying identity-init ConfigMap..."
kubectl apply -n "$NS_FILES" -f "$REPO_ROOT/apps/manifests/nextcloud/identity-init-configmap.yaml"
print_success "Identity-init ConfigMap applied"

# Step 5d.1: Ensure trusted-domains is set in existing identity secret (pre-sync)
# The pod needs trusted_domains in config.php for health probes to pass.
# If the identity secret already exists (from migration or previous deploy) but is
# missing the trusted-domains key, patch it now — before helmfile sync starts the pod.
if kubectl get secret nextcloud-identity -n "$NS_FILES" &>/dev/null; then
    EXISTING_TD=$(kubectl get secret nextcloud-identity -n "$NS_FILES" \
        -o jsonpath='{.data.trusted-domains}' 2>/dev/null || true)
    DESIRED_TD="localhost ${FILES_HOST} ${CALENDAR_HOST:-} nextcloud.${NS_FILES}.svc.cluster.local"
    DESIRED_TD=$(echo "$DESIRED_TD" | xargs)  # trim trailing whitespace
    if [ -z "$EXISTING_TD" ]; then
        print_status "Patching identity secret with trusted-domains (was missing)..."
        kubectl patch secret nextcloud-identity -n "$NS_FILES" \
            -p "{\"data\":{\"trusted-domains\":\"$(echo -n "$DESIRED_TD" | base64)\"}}"
        print_success "trusted-domains added to identity secret"
    else
        DECODED_TD=$(echo "$EXISTING_TD" | base64 -d 2>/dev/null || true)
        if [ "$DECODED_TD" != "$DESIRED_TD" ]; then
            print_status "Updating trusted-domains in identity secret..."
            kubectl patch secret nextcloud-identity -n "$NS_FILES" \
                -p "{\"data\":{\"trusted-domains\":\"$(echo -n "$DESIRED_TD" | base64)\"}}"
            print_success "trusted-domains updated in identity secret"
        else
            print_success "trusted-domains already correct in identity secret"
        fi
    fi
else
    print_status "No identity secret yet (first install) — trusted-domains will be set after install"
fi

# Step 5e: Package custom apps as ConfigMap for init container
# Custom apps (files_linkeditor, jitsi_calendar, guest_bridge) are packaged as a
# tar.gz and stored in a ConfigMap. The seed-identity init container extracts them
# on every pod start, so they survive pod restarts without needing kubectl cp.
print_status "Packaging custom apps into ConfigMap..."
CUSTOM_APPS_STAGING=$(mktemp -d)
CUSTOM_APPS_CHANGED=false

# files_linkeditor
if [ -d "$REPO_ROOT/submodules/files_linkeditor" ]; then
    if [ ! -d "$REPO_ROOT/submodules/files_linkeditor/js" ] && [ ! -f "$REPO_ROOT/submodules/files_linkeditor/js/files_linkeditor-main.js" ]; then
        print_warning "files_linkeditor not built yet. Run './scripts/deploy_infra $MT_ENV' first, or build manually with './scripts/build-linkeditor.sh'"
    fi
    mkdir -p "$CUSTOM_APPS_STAGING/files_linkeditor"
    rsync -a --exclude='node_modules' --exclude='.git' --exclude='dev' \
        "$REPO_ROOT/submodules/files_linkeditor/" "$CUSTOM_APPS_STAGING/files_linkeditor/"
    CUSTOM_APPS_CHANGED=true
fi

# jitsi_calendar (only if calendar is enabled)
if [ "${CALENDAR_ENABLED:-false}" = "true" ] && [ -n "${JITSI_HOST:-}" ]; then
    if [ -d "$REPO_ROOT/apps/jitsi_calendar" ]; then
        mkdir -p "$CUSTOM_APPS_STAGING/jitsi_calendar"
        rsync -a "$REPO_ROOT/apps/jitsi_calendar/" "$CUSTOM_APPS_STAGING/jitsi_calendar/"
        CUSTOM_APPS_CHANGED=true
    fi
fi

# guest_bridge — provisions guest users in Keycloak when sharing with external emails
if [ -d "$REPO_ROOT/apps/nextcloud-guest-bridge" ]; then
    mkdir -p "$CUSTOM_APPS_STAGING/guest_bridge"
    rsync -a "$REPO_ROOT/apps/nextcloud-guest-bridge/" "$CUSTOM_APPS_STAGING/guest_bridge/"
    CUSTOM_APPS_CHANGED=true
fi

if [ "$CUSTOM_APPS_CHANGED" = true ]; then
    # Create tar.gz from the staging directory
    CUSTOM_APPS_TARBALL=$(mktemp /tmp/nextcloud-custom-apps-XXXXXX)
    mv "$CUSTOM_APPS_TARBALL" "${CUSTOM_APPS_TARBALL}.tar.gz"
    CUSTOM_APPS_TARBALL="${CUSTOM_APPS_TARBALL}.tar.gz"
    # Exclude macOS resource fork files (._*) — Nextcloud tries to autoload them as PHP classes
    COPYFILE_DISABLE=1 tar czf "$CUSTOM_APPS_TARBALL" --exclude='._*' -C "$CUSTOM_APPS_STAGING" .
    TARBALL_SIZE=$(du -h "$CUSTOM_APPS_TARBALL" | cut -f1)
    print_status "Custom apps tarball: $TARBALL_SIZE"

    # Create/replace ConfigMap with binaryData
    # Cannot use kubectl apply — the last-applied-configuration annotation would exceed
    # the 262KB annotation size limit for binary data. Use delete+create instead.
    kubectl delete configmap nextcloud-custom-apps --namespace "$NS_FILES" --ignore-not-found=true
    kubectl create configmap nextcloud-custom-apps \
        --namespace "$NS_FILES" \
        --from-file=custom-apps.tar.gz="$CUSTOM_APPS_TARBALL"
    print_success "Custom apps ConfigMap created/updated"

    rm -f "$CUSTOM_APPS_TARBALL"
else
    print_status "No custom apps to package"
fi
rm -rf "$CUSTOM_APPS_STAGING"

# Step 5e.1: Create guest_bridge secret (API URL + key) in files namespace
# The before-starting hook reads these as env vars and writes to per-pod config.php.
# This replaces the old approach of running occ config:system:set on a single pod.
if [ -d "$REPO_ROOT/apps/nextcloud-guest-bridge" ]; then
    GUEST_BRIDGE_API_URL="http://account-portal.${NS_ADMIN}.svc.cluster.local/api/provision-guest"
    GUEST_API_KEY=$(kubectl get secret account-portal-secrets -n "$NS_ADMIN" -o jsonpath='{.data.guest-provisioning-api-key}' 2>/dev/null | base64 -d || echo "")
    if [ -n "$GUEST_API_KEY" ]; then
        kubectl create secret generic nextcloud-guest-bridge \
            --namespace "$NS_FILES" \
            --from-literal=api-url="$GUEST_BRIDGE_API_URL" \
            --from-literal=api-key="$GUEST_API_KEY" \
            --dry-run=client -o yaml | kubectl apply -f -
        print_success "guest_bridge secret created/updated (API: $GUEST_BRIDGE_API_URL)"
    else
        print_warning "Guest provisioning API key not found in account-portal-secrets"
        print_warning "guest_bridge will not provision guests until API key is configured"
        print_warning "Add 'guest_provisioning_api_key' to tenant secrets under 'account_portal' section"
    fi
fi

# Step 5b: Create before-starting hook ConfigMap
# This hook runs on every pod start to enforce OIDC-only login.
# Because /var/www/html is an emptyDir, pod restarts trigger a fresh Nextcloud
# install which resets user_oidc allow_multiple_user_backends to its default (1).
# The hook sets it back to 0, preventing the native login form from appearing.
HOOK_SCRIPT="$REPO_ROOT/apps/manifests/nextcloud/before-starting-hook.sh"
OIDC_HEALTH_SCRIPT="$REPO_ROOT/apps/manifests/nextcloud/oidc-health.php"
if [ -f "$HOOK_SCRIPT" ]; then
    kubectl create configmap nextcloud-before-starting \
        --namespace "$NS_FILES" \
        --from-file=enforce-oidc-login.sh="$HOOK_SCRIPT" \
        --from-file=oidc-health.php="$OIDC_HEALTH_SCRIPT" \
        --dry-run=client -o yaml | kubectl apply -f -
    print_status "before-starting hook ConfigMap created/updated"
fi

# Step 5c: Ensure appstore-urls ConfigMap exists before helmfile sync
# App store apps (user_oidc, calendar, richdocuments, external, notify_push) live on
# emptyDir and are lost on pod restart. The init container downloads them from URLs
# stored in this ConfigMap on every boot.
#
# Versions are pinned in app-versions.json (git-tracked manifest). This ensures ALL
# pods — existing, restarted, HPA-scaled — always get the same app versions. Version
# updates happen via PRs (automated by GitHub Action), not during deploys.
#
# The ConfigMap is always rebuilt from the manifest to ensure consistency.
APP_VERSIONS_FILE="$REPO_ROOT/apps/manifests/nextcloud/app-versions.json"
_build_app_urls_from_manifest() {
    # Build APP_ID|URL lines from app-versions.json
    # Uses authoritative download URLs stored in the manifest (sourced from the
    # Nextcloud app store API), not constructed from a pattern.
    python3 - "$APP_VERSIONS_FILE" <<'PYEOF'
import json, sys, os
with open(sys.argv[1]) as f:
    manifest = json.load(f)
needed = {'user_oidc', 'calendar', 'richdocuments', 'external', 'notify_push'}
if os.environ.get('GOOGLE_IMPORT_ENABLED') == 'true':
    needed.add('integration_google')
for app_id, info in manifest['apps'].items():
    if app_id in needed:
        # Support both formats: {"version": "x", "url": "..."} and plain "version"
        if isinstance(info, dict):
            url = info['url']
        else:
            # Legacy format (version string only) — construct URL from pattern
            version = info
            url = f'https://github.com/nextcloud-releases/{app_id}/releases/download/v{version}/{app_id}-v{version}.tar.gz'
        print(f'{app_id}|{url}')
PYEOF
}

if [ -f "$APP_VERSIONS_FILE" ]; then
    print_status "Building app store URLs from version manifest..."
    APP_URLS=$(_build_app_urls_from_manifest)
    if [ -n "$APP_URLS" ]; then
        kubectl create configmap nextcloud-appstore-urls \
            --namespace "$NS_FILES" \
            --from-literal=app-urls="$APP_URLS" \
            --dry-run=client -o yaml | kubectl apply -f -
        APP_COUNT=$(echo "$APP_URLS" | wc -l | tr -d ' ')
        print_success "App store URLs ConfigMap applied from manifest ($APP_COUNT apps)"
    else
        print_warning "Could not build app URLs from manifest"
    fi
else
    # Fallback for deployments without the manifest file (backward compat)
    if ! kubectl get configmap nextcloud-appstore-urls -n "$NS_FILES" &>/dev/null; then
        print_status "No app-versions.json found, fetching from app store API (first deploy)..."
        NC_CHART_VERSION=$(grep -A3 'chart: nextcloud/nextcloud' "$REPO_ROOT/apps/helmfile.yaml.gotmpl" \
            | grep 'version:' | head -1 | awk '{print $2}')
        if [ -n "$NC_CHART_VERSION" ]; then
            NC_APP_VERSION=$(helm show chart nextcloud/nextcloud --version "$NC_CHART_VERSION" 2>/dev/null \
                | grep '^appVersion:' | awk '{print $2}')
        fi
        if [ -n "${NC_APP_VERSION:-}" ]; then
            APP_URLS=$(curl -sf "https://apps.nextcloud.com/api/v1/platform/${NC_APP_VERSION}/apps.json" | python3 -c "
import json, sys, os
apps = json.load(sys.stdin)
needed = {'user_oidc', 'calendar', 'richdocuments', 'external', 'notify_push'}
if os.environ.get('GOOGLE_IMPORT_ENABLED') == 'true':
    needed.add('integration_google')
for a in apps:
    if a['id'] in needed and a.get('releases'):
        r = a['releases'][0]
        print(f\"{a['id']}|{r['download']}\")
" 2>/dev/null || true)
            if [ -n "$APP_URLS" ]; then
                kubectl create configmap nextcloud-appstore-urls \
                    --namespace "$NS_FILES" \
                    --from-literal=app-urls="$APP_URLS" \
                    --dry-run=client -o yaml | kubectl apply -f -
                APP_COUNT=$(echo "$APP_URLS" | wc -l | tr -d ' ')
                print_success "App store URLs ConfigMap created ($APP_COUNT apps for NC $NC_APP_VERSION)"
            else
                print_warning "Could not fetch app store URLs from API (non-critical for first deploy)"
            fi
        else
            print_warning "Could not determine NC version from Helm chart ${NC_CHART_VERSION:-unknown}"
        fi
    else
        print_status "App store URLs ConfigMap already exists (preserving for version consistency)"
    fi
fi

# Step 6: Deploy Nextcloud via helmfile
# Pre-upgrade: resolve HPA field manager conflict if present.
# The post-deploy HPA behavior patch previously used client-side merge patch
# (kubectl patch --type merge), which sets the field manager to "kubectl-patch"
# via autoscaling/v2. This conflicts with Helm's SSA Apply via autoscaling/v1
# on .spec.maxReplicas. Delete the HPA so Helm can recreate it cleanly.
if kubectl get hpa nextcloud -n "$NS_FILES" --show-managed-fields \
    -o jsonpath='{.metadata.managedFields[*].manager}' 2>/dev/null | grep -q kubectl-patch; then
    print_status "Removing HPA with field manager conflict (Helm will recreate)..."
    kubectl delete hpa nextcloud -n "$NS_FILES"
fi

print_status "Deploying Nextcloud via helmfile..."
pushd "$REPO_ROOT/apps" >/dev/null
  # Use sync instead of apply to skip slow diff operation
  # Use --skip-deps if repos already updated by create_env
  SKIP_DEPS_FLAG=""
  if [ "${SKIP_HELM_REPO_UPDATE:-}" = "true" ]; then
    SKIP_DEPS_FLAG="--skip-deps"
  fi
  # The chart's hpa.enabled=true omits .spec.replicas from the Deployment, avoiding
  # Helm 4 SSA conflicts with kube-controller-manager (which owns .spec.replicas
  # via the HPA scale subresource).
  if helmfile -e "$MT_ENV" -l name=nextcloud sync $SKIP_DEPS_FLAG; then
    print_success "Nextcloud deployed successfully"
  else
    print_error "Nextcloud deployment failed"
    exit 1
  fi
popd >/dev/null

# Step 6b: Route in-cluster traffic through internal ingress (PROXY protocol workaround)
# The external ingress requires PROXY protocol headers (from Cloudflare → NodeBalancer).
# In-cluster pods connecting to external hostnames get ECONNRESET because kube-proxy
# routes directly to the external ingress pod, bypassing the NodeBalancer.
# Fix: Create internal Ingresses (no PROXY protocol) and add hostAliases to the
# Nextcloud pod so it resolves these hostnames via the internal ingress.
print_status "Configuring internal routes for OIDC and Collabora (PROXY protocol workaround)..."

WILDCARD_TLS_SECRET="wildcard-tls-${MT_TENANT}"

# Internal ingress for Keycloak (auth) — required for OIDC login
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak-internal-${MT_TENANT}
  namespace: ${NS_AUTH}
  labels:
    app: keycloak
    tenant: ${MT_TENANT}
    purpose: internal-oidc
  annotations:
    nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "8"
spec:
  ingressClassName: nginx-internal
  rules:
  - host: ${AUTH_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: keycloak-keycloakx-http
            port:
              name: http
  tls:
  - hosts:
    - ${AUTH_HOST}
    secretName: ${WILDCARD_TLS_SECRET}
EOF
print_success "Internal auth Ingress created/updated for ${AUTH_HOST}"

# Internal ingress for Collabora (office) — needed so richdocuments can reach the
# discovery endpoint without hitting the external ingress PROXY protocol wall
if [ "${OFFICE_ENABLED}" = "true" ]; then
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: collabora-internal-${MT_TENANT}
  namespace: ${NS_OFFICE}
  labels:
    app: collabora
    tenant: ${MT_TENANT}
    purpose: internal-office
spec:
  ingressClassName: nginx-internal
  rules:
  - host: ${OFFICE_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: collabora-online
            port:
              number: 9980
  tls:
  - hosts:
    - ${OFFICE_HOST}
    secretName: ${WILDCARD_TLS_SECRET}
EOF
    print_success "Internal Collabora Ingress created/updated for ${OFFICE_HOST}"

    # Internal ingress for Nextcloud (files) — needed so Collabora can reach the
    # WOPI CheckFileInfo endpoint without hitting the external ingress PROXY protocol wall
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nextcloud-internal-${MT_TENANT}
  namespace: ${NS_FILES}
  labels:
    app: nextcloud
    tenant: ${MT_TENANT}
    purpose: internal-wopi
spec:
  ingressClassName: nginx-internal
  rules:
  - host: ${FILES_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nextcloud
            port:
              number: 8080
  tls:
  - hosts:
    - ${FILES_HOST}
    secretName: ${WILDCARD_TLS_SECRET}
EOF
    print_success "Internal Nextcloud Ingress created/updated for ${FILES_HOST}"
fi

# Look up the internal ingress controller's ClusterIP
INTERNAL_INGRESS_IP=$(kubectl get svc ingress-nginx-internal-controller \
    -n "$NS_INGRESS_INTERNAL" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

if [ -z "$INTERNAL_INGRESS_IP" ]; then
    print_warning "Could not find internal ingress controller ClusterIP"
    print_warning "Nextcloud OIDC login may fail (PROXY protocol issue)"
else
    # Build hostnames list: always include AUTH_HOST, add OFFICE_HOST when enabled.
    # All hostnames share one IP, so they go in a single hostAliases entry.
    # (Strategic merge uses 'ip' as the merge key — separate entries with the same
    # IP would overwrite each other instead of merging hostnames.)
    INTERNAL_HOSTNAMES='"'"$AUTH_HOST"'"'
    if [ "${OFFICE_ENABLED}" = "true" ]; then
        INTERNAL_HOSTNAMES="${INTERNAL_HOSTNAMES}"',"'"$OFFICE_HOST"'"'
    fi

    # Patch the Nextcloud deployment to resolve hostnames via internal ingress.
    # Strategic merge patch is idempotent — if hostAliases are already correct, no rollout.
    # Helm's three-way merge preserves third-party changes, so this survives helmfile sync.
    print_status "Adding hostAliases to Nextcloud deployment (${AUTH_HOST}${OFFICE_ENABLED:+, ${OFFICE_HOST}} → ${INTERNAL_INGRESS_IP})..."
    kubectl patch deployment nextcloud -n "$NS_FILES" \
        --type=strategic \
        -p '{"spec":{"template":{"spec":{"hostAliases":[{"ip":"'"$INTERNAL_INGRESS_IP"'","hostnames":['"$INTERNAL_HOSTNAMES"']}]}}}}'

    # Wait for rollout to complete (immediate if patch was a no-op)
    kubectl rollout status deployment/nextcloud -n "$NS_FILES" --timeout=600s
    print_success "Nextcloud configured to route traffic internally"

    # Patch the Collabora deployment so it resolves FILES_HOST via internal ingress.
    # Without this, Collabora's WOPI CheckFileInfo callback to https://FILES_HOST/...
    # hits the external ingress (which requires PROXY protocol) and gets ECONNRESET.
    if [ "${OFFICE_ENABLED}" = "true" ]; then
        print_status "Adding hostAliases to Collabora deployment (${FILES_HOST} → ${INTERNAL_INGRESS_IP})..."
        kubectl patch deployment collabora-online -n "$NS_OFFICE" \
            --type=strategic \
            -p '{"spec":{"template":{"spec":{"hostAliases":[{"ip":"'"$INTERNAL_INGRESS_IP"'","hostnames":["'"$FILES_HOST"'"]}]}}}}'

        kubectl rollout status deployment/collabora-online -n "$NS_OFFICE" --timeout=300s
        print_success "Collabora configured to route WOPI traffic internally"
    fi
fi

# Step 7: Wait for Nextcloud to be ready
print_status "Waiting for Nextcloud pod to be ready (this may take a few minutes)..."
if ! poll_pod_ready "$NS_FILES" "app.kubernetes.io/instance=nextcloud" 600 5; then
    print_error "Nextcloud pod did not become ready."
    print_error "Refusing to continue (OIDC job / kubectl exec / kubectl cp require a scheduled, running pod)."
    exit 1
fi

# Step 7a: Run occ upgrade if Nextcloud requires it (e.g. image version bump)
# When the container image is newer than the DB schema, Nextcloud blocks all occ
# commands until `occ upgrade` runs. Detect this and handle it automatically.
NEXTCLOUD_POD_UPGRADE=$(_get_nc_pod)
if [ -n "$NEXTCLOUD_POD_UPGRADE" ]; then
    UPGRADE_CHECK=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD_UPGRADE" -c nextcloud -- su -s /bin/sh www-data -c 'php occ status --output=json' 2>&1 || true)
    if echo "$UPGRADE_CHECK" | grep -q "require upgrade"; then
        print_status "Nextcloud requires database upgrade (image version newer than DB schema)..."
        if timeout 300 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD_UPGRADE" -c nextcloud -- su -s /bin/sh www-data -c 'php occ upgrade' 2>&1; then
            print_success "Nextcloud database upgrade completed"
        else
            print_error "Nextcloud occ upgrade failed"
            exit 1
        fi
    fi
fi

# Step 7b: Extract/update identity secret from running pod
# After first install: extract instanceid, passwordsalt, secret and create the identity secret.
# On every deploy: update the version key to match the installed version.
print_status "Managing Nextcloud identity secret..."
NEXTCLOUD_POD=$(_get_nc_pod)
if [ -n "$NEXTCLOUD_POD" ]; then
    # Wait for config.php to appear (entrypoint creates it during first install)
    for attempt in $(seq 1 60); do
        if timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- test -f /var/www/html/config/config.php 2>/dev/null; then
            break
        fi
        if [ $attempt -eq 60 ]; then
            print_warning "config.php not found after 60 attempts, skipping identity extraction"
        fi
        sleep 5
    done

    if timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- test -f /var/www/html/config/config.php 2>/dev/null; then
        # Extract identity values using PHP for accurate parsing
        # (grep is unreliable — e.g. 'secret' key also appears inside objectstore.arguments)
        CURRENT_INSTANCE_ID=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
            php -r 'include "/var/www/html/config/config.php"; echo $CONFIG["instanceid"] ?? "";' 2>/dev/null || true)
        CURRENT_PASSWORD_SALT=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
            php -r 'include "/var/www/html/config/config.php"; echo $CONFIG["passwordsalt"] ?? "";' 2>/dev/null || true)
        CURRENT_SECRET=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
            php -r 'include "/var/www/html/config/config.php"; echo $CONFIG["secret"] ?? "";' 2>/dev/null || true)
        CURRENT_VERSION=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
            php -r 'require "/var/www/html/version.php"; echo implode(".", $OC_Version);' 2>/dev/null || true)

        if [ -n "$CURRENT_INSTANCE_ID" ] && [ -n "$CURRENT_PASSWORD_SALT" ] && [ -n "$CURRENT_SECRET" ]; then
            kubectl create secret generic nextcloud-identity \
                --namespace "$NS_FILES" \
                --from-literal=instanceid="$CURRENT_INSTANCE_ID" \
                --from-literal=passwordsalt="$CURRENT_PASSWORD_SALT" \
                --from-literal=secret="$CURRENT_SECRET" \
                --from-literal=version="${CURRENT_VERSION:-unknown}" \
                --from-literal=trusted-domains="localhost ${FILES_HOST} ${CALENDAR_HOST:-} nextcloud.${NS_FILES}.svc.cluster.local" \
                --dry-run=client -o yaml | kubectl apply -f -
            print_success "Identity secret created/updated (instanceid=$CURRENT_INSTANCE_ID, version=$CURRENT_VERSION)"
        else
            print_warning "Could not extract identity values from config.php"
        fi
    fi
else
    print_warning "Nextcloud pod not found, skipping identity secret management"
fi

# Step 7c: Reconcile trusted_domains (ensure calendar host is included)
print_status "Checking trusted_domains configuration..."
NEXTCLOUD_POD=$(_get_nc_pod)
if [ -n "$NEXTCLOUD_POD" ]; then
    if timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- test -f /var/www/html/config/config.php 2>/dev/null; then
        # Get current trusted_domains list
        CURRENT_DOMAINS=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
            php /var/www/html/occ config:system:get trusted_domains 2>/dev/null || true)

        # Ensure FILES_HOST is in trusted_domains
        if [ -n "${FILES_HOST:-}" ] && ! echo "$CURRENT_DOMAINS" | grep -qF "$FILES_HOST"; then
            NEXT_INDEX=$(echo "$CURRENT_DOMAINS" | grep -c '.' || echo "0")
            kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
                php /var/www/html/occ config:system:set trusted_domains "$NEXT_INDEX" --value="$FILES_HOST"
            print_success "Added $FILES_HOST to trusted_domains"
        fi

        # Ensure CALENDAR_HOST is in trusted_domains (when calendar is enabled)
        if [ "${CALENDAR_ENABLED:-false}" = "true" ] && [ -n "${CALENDAR_HOST:-}" ]; then
            if ! echo "$CURRENT_DOMAINS" | grep -qF "$CALENDAR_HOST"; then
                # Re-read in case we just added FILES_HOST
                CURRENT_DOMAINS=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
                    php /var/www/html/occ config:system:get trusted_domains 2>/dev/null || true)
                NEXT_INDEX=$(echo "$CURRENT_DOMAINS" | grep -c '.' || echo "0")
                kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
                    php /var/www/html/occ config:system:set trusted_domains "$NEXT_INDEX" --value="$CALENDAR_HOST"
                print_success "Added $CALENDAR_HOST to trusted_domains"
            else
                print_success "trusted_domains already includes $CALENDAR_HOST"
            fi
        fi
    else
        print_status "No config.php yet (new installation), trusted_domains will be set at install time"
    fi
else
    print_warning "Nextcloud pod not found, skipping trusted_domains check"
fi

# Step 7d: Set overwrite.cli.url for pretty URLs (.htaccess rewrites)
# Without this, Apache can't rewrite /apps/calendar (and similar paths) to index.php,
# causing 404 errors on the calendar subdomain and any pretty URL route.
print_status "Configuring overwrite.cli.url for pretty URLs..."
NEXTCLOUD_POD=$(_get_nc_pod)
if [ -n "$NEXTCLOUD_POD" ]; then
    if timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- test -f /var/www/html/config/config.php 2>/dev/null; then
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
            su -s /bin/sh www-data -c "php occ config:system:set overwrite.cli.url --value='https://$FILES_HOST'" 2>/dev/null && \
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
            su -s /bin/sh www-data -c "php occ maintenance:update:htaccess" 2>/dev/null && \
        print_success "overwrite.cli.url set and .htaccess updated" || \
        print_warning "Failed to set overwrite.cli.url (non-critical on first install)"
    fi
else
    print_warning "Nextcloud pod not found, skipping overwrite.cli.url"
fi

# Step 8: Generate and apply OIDC configuration job from template
print_status "Configuring OIDC authentication via Job..."

# First, wait for Nextcloud installation to complete
print_status "Waiting for Nextcloud installation to complete..."
NEXTCLOUD_POD=$(_get_nc_pod)
if [ -n "$NEXTCLOUD_POD" ]; then
    for attempt in $(seq 1 30); do
        INSTALLED=$(timeout 30 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- cat /var/www/html/config/config.php 2>/dev/null | grep "'installed'" | grep "true" || true)
        if [ -n "$INSTALLED" ]; then
            print_success "Nextcloud installation confirmed"

            # Add missing database indexes (safe to run repeatedly, only adds what's missing)
            print_status "Checking for missing database indexes..."
            kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
                su -s /bin/sh www-data -c "php occ db:add-missing-indices" 2>/dev/null || \
                print_warning "db:add-missing-indices failed (non-critical)"

            break
        fi
        if [ $attempt -eq 30 ]; then
            print_error "Nextcloud installation check timed out after 30 attempts."
            print_error "Refusing to run OIDC configuration job until installation completes (it will just fail/retry noisily)."
            exit 1
        fi
        echo "Waiting for Nextcloud installation... (attempt $attempt/30)"
        sleep 10
    done
else
    print_error "Nextcloud pod not found. Refusing to run OIDC configuration job."
    dump_pod_diagnostics "$NS_FILES" "app.kubernetes.io/instance=nextcloud"
    exit 1
fi

if [ -f "$REPO_ROOT/docs/nextcloud-oidc-config-job.yaml.tpl" ]; then
    # Apply RBAC resources first (with namespace substitution)
    if [ -f "$REPO_ROOT/docs/nextcloud-oidc-rbac.yaml" ]; then
        cat "$REPO_ROOT/docs/nextcloud-oidc-rbac.yaml" | sed "s/namespace: files/namespace: $NS_FILES/g" | kubectl apply -f -
        print_status "OIDC RBAC resources applied"
        sleep 2
    fi

    # Generate the job manifest from template
    envsubst '${FILES_HOST} ${AUTH_HOST} ${TENANT_KEYCLOAK_REALM} ${CALENDAR_ENABLED} ${SMTP_DOMAIN} ${JITSI_HOST} ${OFFICE_ENABLED} ${OFFICE_HOST} ${NS_OFFICE} ${GOOGLE_IMPORT_ENABLED}' < "$REPO_ROOT/docs/nextcloud-oidc-config-job.yaml.tpl" | \
      sed "s/namespace: files/namespace: $NS_FILES/g" > /tmp/nextcloud-oidc-config-job.yaml

    # Delete previous job if exists
    kubectl -n "$NS_FILES" delete job/nextcloud-oidc-config --ignore-not-found=true || true

    # Apply the job
    kubectl apply -f /tmp/nextcloud-oidc-config-job.yaml

    # Wait for job to complete
    if poll_job_complete "$NS_FILES" "nextcloud-oidc-config" 600 5; then
        print_success "OIDC configuration completed"
    else
        print_warning "OIDC configuration job may still be running or failed"
    fi
else
    print_warning "OIDC config job template not found, skipping OIDC configuration"
fi

# Step 8b: Flush APCu route cache after OIDC job installs apps
# The OIDC config job installs apps (user_oidc, calendar, richdocuments, external) to
# custom_apps/. Nextcloud caches compiled route tables in APCu keyed by hostname.
# If the route cache was built before these apps were installed (e.g. by a health probe),
# the external hostname's cache won't include the new app routes, causing 404 errors.
# Flushing APCu forces Nextcloud to rebuild the route table with all installed apps.
print_status "Flushing APCu route cache (graceful Apache restart)..."
NEXTCLOUD_POD=$(_get_nc_pod)
if [ -n "$NEXTCLOUD_POD" ]; then
    # APCu is per-process in Apache prefork mode. A graceful restart (SIGUSR1) recreates
    # all child workers, clearing their APCu caches. The parent process stays alive (PID 1),
    # so the container doesn't restart. This ensures ALL route caches are rebuilt fresh
    # with the newly installed apps included.
    kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- apache2ctl graceful \
        && print_success "APCu cache flushed (Apache graceful restart)" \
        || print_warning "APCu cache flush failed (non-critical — cache will rebuild on next request)"
fi

# Step 9: Configure files_linkeditor app (custom apps are already deployed via ConfigMap)
# The init container extracts custom apps from the ConfigMap on every boot.
# Here we just run the occ commands to enable/configure the app.
print_status "Configuring files_linkeditor app..."
if [ -d "$REPO_ROOT/submodules/files_linkeditor" ]; then
    NEXTCLOUD_POD=$(_get_nc_pod)
    if [ -n "$NEXTCLOUD_POD" ]; then
        # Update MIME type mappings (mimetypemapping.json is written by init container)
        print_status "Updating MIME type mappings..."
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- su -s /bin/sh www-data -c "php occ maintenance:mimetype:update-js" 2>/dev/null || true
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- su -s /bin/sh www-data -c "php occ maintenance:mimetype:update-db --repair-filecache" 2>/dev/null || true
        print_success "MIME type mappings updated"

        # Configure files_linkeditor app settings for DOCX conversion
        print_status "Configuring files_linkeditor app settings..."

        # Get Y-Provider API key from docs secrets
        YPROVIDER_API_KEY=$(kubectl get secret -n "$NS_DOCS" docs-secrets -o jsonpath='{.data.Y_PROVIDER_API_KEY}' 2>/dev/null | base64 -d) || true

        if [ -n "$YPROVIDER_API_KEY" ]; then
            kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- su -s /bin/sh www-data -c "php occ config:app:set files_linkeditor docs_url --value='https://$DOCS_HOST'"
            kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- su -s /bin/sh www-data -c "php occ config:app:set files_linkeditor yprovider_url --value='http://y-provider.$NS_DOCS.svc.cluster.local:4444/api'"
            kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- su -s /bin/sh www-data -c "php occ config:app:set files_linkeditor yprovider_api_key --value='$YPROVIDER_API_KEY'"
            print_success "files_linkeditor app configured with Y-Provider settings"
        else
            print_warning "Could not retrieve Y-Provider API key from docs-secrets, skipping Y-Provider configuration"
        fi
    else
        print_warning "Nextcloud pod not found, skipping custom app configuration"
    fi
else
    print_warning "files_linkeditor submodule not found at $REPO_ROOT/submodules/files_linkeditor"
fi

# Step 9b: jitsi_calendar app is deployed via ConfigMap (extracted by init container)
# No kubectl cp needed — just log that it's included
if [ "${CALENDAR_ENABLED:-false}" = "true" ] && [ -n "${JITSI_HOST:-}" ]; then
    if [ -d "$REPO_ROOT/apps/jitsi_calendar" ]; then
        print_success "jitsi_calendar app included in custom apps ConfigMap"
    else
        print_warning "jitsi_calendar app not found at $REPO_ROOT/apps/jitsi_calendar"
    fi
else
    print_status "Skipping jitsi_calendar (calendar not enabled or JITSI_HOST not set)"
fi

# Step 9b.1: Verify guest_bridge configuration
# App enabling and API config are handled by the before-starting hook (runs on every pod).
# The hook reads GUEST_BRIDGE_API_URL and GUEST_BRIDGE_API_KEY from the K8s secret
# (created in step 5e.1) and writes to per-pod config.php via occ config:system:set.
# Here we just verify connectivity from any running pod.
if [ -d "$REPO_ROOT/apps/nextcloud-guest-bridge" ]; then
    NEXTCLOUD_POD=$(_get_nc_pod)
    if [ -n "$NEXTCLOUD_POD" ]; then
        print_status "Verifying guest_bridge connectivity to account portal..."
        HEALTH_CHECK=$(kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
            curl -sf -o /dev/null -w "%{http_code}" \
            --connect-timeout 5 --max-time 10 \
            "http://account-portal.${NS_ADMIN}.svc.cluster.local/health" 2>/dev/null || echo "000")
        if [ "$HEALTH_CHECK" = "200" ]; then
            print_success "guest_bridge → account portal connectivity verified"
        else
            print_warning "guest_bridge cannot reach account portal (HTTP $HEALTH_CHECK)"
            print_warning "Guest provisioning may fail — check network policies and account-portal deployment"
        fi
    fi
fi

# Step 9c: Deploy notify_push (Client Push) — replaces browser polling with WebSocket push
print_status "Deploying notify_push (Client Push)..."
NEXTCLOUD_POD=$(_get_nc_pod)
if [ -n "$NEXTCLOUD_POD" ]; then
    # Build connection URLs from values already available in this script
    # URL-encode passwords: base64 can contain +, /, = which break URL parsing
    url_encode() { python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.stdin.read().strip(), safe=''))"; }
    DB_PASSWORD_ENCODED=$(printf '%s' "$DB_PASSWORD" | url_encode)
    REDIS_PASSWORD_ENCODED=$(printf '%s' "$REDIS_PASSWORD" | url_encode)
    NOTIFY_PUSH_DB_URL="postgres://${TENANT_DB_USER}:${DB_PASSWORD_ENCODED}@${PG_HOST}/${NEXTCLOUD_DB_NAME}"
    NOTIFY_PUSH_REDIS_URL="redis://:${REDIS_PASSWORD_ENCODED}@redis.${NS_FILES}.svc.cluster.local:6379"

    # Create/update the notify-push-config secret
    kubectl create secret generic notify-push-config \
        --namespace "$NS_FILES" \
        --from-literal=DATABASE_URL="$NOTIFY_PUSH_DB_URL" \
        --from-literal=REDIS_URL="$NOTIFY_PUSH_REDIS_URL" \
        --dry-run=client -o yaml | kubectl apply -f -
    print_success "notify-push-config secret created/updated"

    # Apply the Deployment + Service manifest (envsubst for NS_FILES)
    envsubst '${NS_FILES}' < "$REPO_ROOT/apps/manifests/nextcloud/notify-push.yaml" | kubectl apply -n "$NS_FILES" -f -
    print_success "notify-push Deployment and Service applied"

    # Wait for the notify-push pod to be ready
    if ! poll_pod_ready "$NS_FILES" "app=notify-push" 120 5; then
        print_warning "notify-push pod not ready yet — check logs with: kubectl logs -n $NS_FILES -l app=notify-push"
        print_warning "Continuing deployment (notify_push is non-critical)..."
    else
        # Install and enable the PHP-side notify_push app in Nextcloud
        print_status "Installing notify_push PHP app..."
        # app:install downloads from the app store; if already present, just enable
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
            su -s /bin/sh www-data -c "php occ app:install notify_push" 2>/dev/null || \
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
            su -s /bin/sh www-data -c "php occ app:enable notify_push" 2>/dev/null || true
        print_success "notify_push PHP app installed/enabled"

        # Configure the push endpoint URL (must match the ingress path)
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
            su -s /bin/sh www-data -c "php occ config:app:set notify_push base_endpoint --value='https://${FILES_HOST}/push'"
        print_success "notify_push base_endpoint set to https://${FILES_HOST}/push"

        # Add the internal push service as a trusted proxy so X-Forwarded-For is honoured
        kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
            su -s /bin/sh www-data -c "php occ config:system:set trusted_proxies 0 --value='10.0.0.0/8'" 2>/dev/null || true

        # Run the built-in self-test (verifies Redis, DB, HTTP connectivity, and a test push event)
        print_status "Running notify_push self-test..."
        if kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- \
            su -s /bin/sh www-data -c "php occ notify_push:self-test" 2>&1; then
            print_success "notify_push self-test passed"
        else
            print_warning "notify_push self-test failed (may need a moment to connect — re-run manually)"
            print_warning "  kubectl exec -n $NS_FILES $NEXTCLOUD_POD -- su -s /bin/sh www-data -c 'php occ notify_push:self-test'"
        fi
    fi
else
    print_warning "Nextcloud pod not found, skipping notify_push deployment"
fi

# Step 9c.1: Reconcile app store download URLs ConfigMap (post-deploy, post-theming)
# When using app-versions.json, this is a no-op (ConfigMap was already set from manifest
# in step 5c). For legacy deployments without the manifest, refresh from the API.
if [ -f "$APP_VERSIONS_FILE" ]; then
    # Manifest-based: rebuild from manifest (idempotent, ensures ConfigMap matches)
    print_status "Reconciling app store URLs ConfigMap from manifest..."
    APP_URLS=$(_build_app_urls_from_manifest)
    if [ -n "$APP_URLS" ]; then
        kubectl create configmap nextcloud-appstore-urls \
            --namespace "$NS_FILES" \
            --from-literal=app-urls="$APP_URLS" \
            --dry-run=client -o yaml | kubectl apply -f -
        print_success "App store URLs ConfigMap reconciled from manifest"
    fi
else
    # Legacy: fetch latest compatible versions from API (original behavior)
    print_status "Refreshing app store download URLs ConfigMap from API..."
    NEXTCLOUD_POD=$(_get_nc_pod)
    if [ -n "$NEXTCLOUD_POD" ]; then
        NC_API_VERSION=$(kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
            php -r 'require "/var/www/html/version.php"; echo $OC_Version[0].".".$OC_Version[1].".".$OC_Version[2];' 2>/dev/null || true)
        if [ -n "$NC_API_VERSION" ]; then
            APP_URLS=$(curl -sf "https://apps.nextcloud.com/api/v1/platform/${NC_API_VERSION}/apps.json" | python3 -c "
import json, sys, os
apps = json.load(sys.stdin)
needed = {'user_oidc', 'calendar', 'richdocuments', 'external', 'notify_push'}
if os.environ.get('GOOGLE_IMPORT_ENABLED') == 'true':
    needed.add('integration_google')
for a in apps:
    if a['id'] in needed and a.get('releases'):
        r = a['releases'][0]
        print(f\"{a['id']}|{r['download']}\")
" 2>/dev/null || true)
            if [ -n "$APP_URLS" ]; then
                kubectl create configmap nextcloud-appstore-urls \
                    --namespace "$NS_FILES" \
                    --from-literal=app-urls="$APP_URLS" \
                    --dry-run=client -o yaml | kubectl apply -f -
                APP_COUNT=$(echo "$APP_URLS" | wc -l | tr -d ' ')
                print_success "App store URLs ConfigMap refreshed ($APP_COUNT apps for NC $NC_API_VERSION)"
            else
                print_warning "Could not fetch app store URLs (non-critical — apps already installed on current pod)"
            fi
        else
            print_warning "Could not determine Nextcloud version, skipping app store URL ConfigMap"
        fi
    else
        print_warning "Nextcloud pod not found, skipping app store URL ConfigMap"
    fi
fi

# Step 9d: Configure Nextcloud theming (brand colors, logo, name)
# Each occ command uses _nc_occ_retry which automatically detects "require upgrade"
# errors (caused by HPA-scaled pods running occ upgrade via their before-starting
# hook) and recovers by re-running occ upgrade before retrying the command.
print_status "Configuring Nextcloud theming..."
NEXTCLOUD_POD=$(_get_nc_pod)
if [ -n "$NEXTCLOUD_POD" ]; then
    # Initial reconciliation — catches any drift since step 7a.
    UPGRADE_OUTPUT=$(timeout 300 kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
        su -s /bin/sh www-data -c 'php occ upgrade --no-interaction' 2>&1) || {
        print_warning "occ upgrade returned non-zero on $NEXTCLOUD_POD (may be first install):"
        echo "$UPGRADE_OUTPUT" | tail -5 | while read -r line; do print_warning "  $line"; done
    }

    # Ensure theming app is enabled
    _nc_occ_retry "$NEXTCLOUD_POD" "php occ app:enable theming" 2>/dev/null || true

    # Set primary brand color (sage green)
    _nc_occ_retry "$NEXTCLOUD_POD" "php occ theming:config primary_color '#A7AE8D'"
    print_success "Primary color set to #A7AE8D (sage)"

    # Set instance name from tenant display name
    THEMING_NAME="${TENANT_DISPLAY_NAME:-Mothertree}"
    _nc_occ_retry "$NEXTCLOUD_POD" "php occ theming:config name '$THEMING_NAME'"
    print_success "Instance name set to: $THEMING_NAME"

    # Set URL (link target when clicking instance name)
    THEMING_URL="https://${TENANT_DOMAIN}"
    _nc_occ_retry "$NEXTCLOUD_POD" "php occ theming:config url '$THEMING_URL'"
    print_success "Instance URL set to: $THEMING_URL"

    # Set legal/policy links (from tenant config, exported by config.sh)
    if [ -n "${TERMS_OF_USE_URL:-}" ]; then
        _nc_occ_retry "$NEXTCLOUD_POD" "php occ theming:config imprintUrl '$TERMS_OF_USE_URL'"
        print_success "Legal notice URL set"
    fi
    if [ -n "${PRIVACY_POLICY_URL:-}" ]; then
        _nc_occ_retry "$NEXTCLOUD_POD" "php occ theming:config privacyUrl '$PRIVACY_POLICY_URL'"
        print_success "Privacy policy URL set"
    fi

    # Copy logo files to the pod and apply them
    ASSETS_DIR="$REPO_ROOT/apps/assets/nextcloud"
    if [ -d "$ASSETS_DIR" ]; then
        # Login page logo (dark/coal version for light backgrounds)
        if [ -f "$ASSETS_DIR/logo.svg" ]; then
            kubectl cp "$ASSETS_DIR/logo.svg" "$NS_FILES/$NEXTCLOUD_POD:/tmp/mt-logo.svg"
            _nc_occ_retry "$NEXTCLOUD_POD" "php occ theming:config logo /tmp/mt-logo.svg"
            kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- rm -f /tmp/mt-logo.svg
            print_success "Login logo applied (dark variant)"
        fi

        # Header logo (same coal version — visible on ash background)
        if [ -f "$ASSETS_DIR/logo.svg" ]; then
            kubectl cp "$ASSETS_DIR/logo.svg" "$NS_FILES/$NEXTCLOUD_POD:/tmp/mt-logoheader.svg"
            _nc_occ_retry "$NEXTCLOUD_POD" "php occ theming:config logoheader /tmp/mt-logoheader.svg"
            kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- rm -f /tmp/mt-logoheader.svg
            print_success "Header logo applied (coal variant)"
        fi

        # Favicon
        if [ -f "$ASSETS_DIR/favicon.svg" ]; then
            kubectl cp "$ASSETS_DIR/favicon.svg" "$NS_FILES/$NEXTCLOUD_POD:/tmp/mt-favicon.svg"
            _nc_occ_retry "$NEXTCLOUD_POD" "php occ theming:config favicon /tmp/mt-favicon.svg"
            kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -- rm -f /tmp/mt-favicon.svg
            print_success "Favicon applied"
        fi
    else
        print_warning "Theming assets not found at $ASSETS_DIR, skipping logo/favicon"
    fi

    # Set background to plain color mode (removes default blue watercolor wallpaper)
    _nc_occ_retry "$NEXTCLOUD_POD" "php occ theming:config background 'backgroundColor'"
    # Set the actual background color (ghost fern)
    _nc_occ_retry "$NEXTCLOUD_POD" "php occ theming:config background_color '#A7AE8D'"

    # Enforce brand colors for all users (users can still toggle light/dark mode)
    _nc_occ_retry "$NEXTCLOUD_POD" "php occ theming:config disable-user-theming yes"

    print_success "Nextcloud theming configured"
else
    print_warning "Nextcloud pod not found, skipping theming configuration"
fi

# Step 10: Deploy Grafana dashboard
print_status "Deploying Nextcloud Grafana dashboard..."
if [ -f "$REPO_ROOT/apps/manifests/nextcloud/nextcloud-dashboard-configmap.yaml" ]; then
    cat "$REPO_ROOT/apps/manifests/nextcloud/nextcloud-dashboard-configmap.yaml" | sed "s/namespace: monitoring/namespace: $NS_MONITORING/g" | kubectl apply -f -
    print_success "Nextcloud Grafana dashboard deployed"
else
    print_warning "Grafana dashboard configmap not found, skipping"
fi

# Step 11: HPA management
# Clean up the old custom HPA if it exists from a previous deploy
if kubectl get hpa nextcloud-hpa -n "$NS_FILES" &>/dev/null; then
    print_status "Removing old custom HPA (now managed by chart)..."
    kubectl delete hpa nextcloud-hpa -n "$NS_FILES"
    print_success "Old custom HPA removed"
fi

if [ "$NEXTCLOUD_MIN_REPLICAS" != "$NEXTCLOUD_MAX_REPLICAS" ]; then
    # HPA managed by chart (hpa.enabled=true in values)
    # Patch the chart's HPA with scaleDown stabilization window.
    # The chart's HPA template (autoscaling/v1) doesn't support behavior config,
    # so we patch it post-deploy via server-side apply with a dedicated field manager.
    print_status "Patching HPA scaleDown stabilization window (${NEXTCLOUD_HPA_SCALEDOWN_WINDOW}s)..."
    kubectl apply --server-side --field-manager=nextcloud-hpa-behavior --force-conflicts -f - <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: nextcloud
  namespace: ${NS_FILES}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nextcloud
  minReplicas: ${NEXTCLOUD_MIN_REPLICAS}
  maxReplicas: ${NEXTCLOUD_MAX_REPLICAS}
  behavior:
    scaleDown:
      stabilizationWindowSeconds: ${NEXTCLOUD_HPA_SCALEDOWN_WINDOW}
EOF
    print_success "Nextcloud HPA managed by chart (CPU 80%, min=${NEXTCLOUD_MIN_REPLICAS}, max=${NEXTCLOUD_MAX_REPLICAS}, scaleDown window=${NEXTCLOUD_HPA_SCALEDOWN_WINDOW}s)"
else
    # Fixed replicas — remove any chart-created HPA
    kubectl delete hpa nextcloud -n "$NS_FILES" --ignore-not-found >/dev/null 2>&1
    print_status "Nextcloud: fixed replicas ($NEXTCLOUD_MIN_REPLICAS), HPA removed"
fi

# Migration notice: old PVC
if [ -n "${PVC_EXISTS:-}" ]; then
    echo ""
    print_status "NOTE: Old PVC 'nextcloud-nextcloud' still exists in $NS_FILES."
    print_status "Nextcloud now uses emptyDir with identity from K8s Secret."
    print_status "After verifying everything works, you can safely delete it:"
    print_status "  kubectl delete pvc nextcloud-nextcloud -n $NS_FILES"
fi

print_success "Nextcloud deployment completed!"
echo ""
echo "Access Information:"
echo "  URL: https://$FILES_HOST"
echo "  OIDC Provider: https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}"
echo ""
echo "Namespace Information:"
echo "  Database namespace: $NS_DB"
echo "  Files namespace: $NS_FILES"
echo ""
echo "To check the status:"
echo "  kubectl get pods -n $NS_FILES"
echo "  kubectl get ingress -n $NS_FILES"
echo "  kubectl logs -f deployment/nextcloud -n $NS_FILES"
