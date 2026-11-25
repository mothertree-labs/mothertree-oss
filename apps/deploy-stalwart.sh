#!/bin/bash

# Deploy Stalwart Mail Server using static Kubernetes manifests
# This script applies environment-specific Stalwart manifests using envsubst
#
# Namespace structure:
#   - Stalwart in NS_STALWART (tenant-prefixed namespace, e.g., 'tn-example-mail')
#
# Prerequisites:
#   - PostgreSQL database created in infra-db namespace
#   - S3 bucket created for mail storage
#   - Keycloak OIDC client configured
#
# Usage:
#   ./apps/deploy-stalwart.sh -e dev -t example

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy Stalwart Mail Server for a tenant."
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

# Load infrastructure credentials — provides SES_SMTP_* env vars when SES is
# configured for this env. Absent on dev → Stalwart falls back to direct MX delivery.
source "${REPO_ROOT}/scripts/lib/infra-config.sh"
mt_load_infra_config

source "${REPO_ROOT}/scripts/lib/notify.sh"
mt_deploy_start "deploy-stalwart"

mt_require_commands kubectl envsubst jq

# Override NS_MAIL for envsubst templates that use ${NS_MAIL} to mean
# the tenant mail namespace (stalwart templates expect this)
export NS_MAIL="$NS_STALWART"

print_status "Deploying Stalwart Mail Server for environment: $MT_ENV"
print_status "Tenant: $TENANT"
print_status "Mail namespace: $NS_MAIL"

# Check if mail_enabled feature flag is set
if [ "$MAIL_ENABLED" != "true" ]; then
    print_warning "Mail not enabled for tenant $TENANT (features.mail_enabled is not true)"
    print_warning "Skipping Stalwart deployment"
    exit 0
fi

# Validate database config
if [ -z "$STALWART_DB_NAME" ] || [ "$STALWART_DB_NAME" = "null" ]; then
    print_error "STALWART_DB_NAME not set. Add 'database.stalwart_db' to tenant config"
    exit 1
fi
print_status "Database: $STALWART_DB_NAME (user: $STALWART_DB_USER)"
: "${STALWART_V1_DB_NAME:?STALWART_V1_DB_NAME not set by config.sh}"
: "${STALWART_SCRATCH_DB_NAME:?STALWART_SCRATCH_DB_NAME not set by config.sh}"
if [ "$STALWART_V1_DB_NAME" = "$STALWART_DB_NAME" ] || [ "$STALWART_SCRATCH_DB_NAME" = "$STALWART_DB_NAME" ]; then
    print_error "STALWART_V1_DB_NAME and STALWART_SCRATCH_DB_NAME must differ from STALWART_DB_NAME (the live 0.15 store)"
    exit 1
fi

# Validate PG_HOST
if [ -z "${PG_HOST:-}" ]; then
    print_error "PostgreSQL not found. Run 'deploy_infra $MT_ENV' first."
    exit 1
fi

# Resource configuration
print_status "Mail ports: SMTPS=${STALWART_SMTPS_PORT}, Submission=${STALWART_SUBMISSION_PORT}, IMAPS=${STALWART_IMAPS_PORT}"
print_status "App password ports: IMAPS=${STALWART_IMAPS_APP_PORT}, Submission=${STALWART_SUBMISSION_APP_PORT}"

# Validate mail ports are configured
for port_var in STALWART_SMTPS_PORT STALWART_SUBMISSION_PORT STALWART_IMAPS_PORT STALWART_IMAPS_APP_PORT STALWART_SUBMISSION_APP_PORT; do
    val="${!port_var:-}"
    if [ -z "$val" ] || [ "$val" = "null" ]; then
        print_error "$port_var not configured. Add the corresponding resources.stalwart.* config"
        exit 1
    fi
done

print_status "Mail host: $MAIL_HOST"
print_status "Auth host: $AUTH_HOST"
print_status "Admin host: $WEBADMIN_HOST"
print_status "Email domain: $EMAIL_DOMAIN (for inbound mail routing)"

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
    print_error "Update tenant secrets file with actual values"
    exit 1
fi

# Validate S3 bucket
if [ -z "$S3_MAIL_BUCKET" ] || [ "$S3_MAIL_BUCKET" = "null" ]; then
    print_error "S3 mail bucket not configured in tenant config"
    print_error "Add 's3.mail_bucket' to the tenant config"
    exit 1
fi

# =============================================================================
# Outbound mail path: SES relay (prod) or direct MX (dev)
# =============================================================================
# Outbound DKIM signing is delegated to AWS SES Easy DKIM — Stalwart doesn't
# sign. SES rewrites Message-ID and Date during relay, which invalidates any
# Stalwart-side signature by the time it reaches the receiver. SES signs
# post-mutation with its own rotated keys, and DMARC carries via that
# signature's d=<tenant-domain> alignment.
#
# Route choice is environment-dependent:
#   - SES configured (prod): relay via AWS SES on 587 with SASL auth. The
#     ses-credentials Secret carries endpoint/username/password, mounted as
#     env vars referenced by %{env:...}% in the relay route block.
#   - mail.smtp_relay in the infra config (devhome): relay via an
#     unauthenticated smart host on the tailnet (the periscope's Postfix,
#     which authorizes the box by source address). Residential ISPs block
#     outbound 25, so direct MX cannot work from a home box. Setting this AND
#     SES is a config error: the route would be ambiguous.
#   - Neither (dev): direct MX delivery from the cluster's egress IP. No
#     smart host. Cluster egress IP has no PTR/SPF so receivers may tempfail,
#     but that matches the existing dev behavior (see project_mail_paths_per_env).
#
# `.dkim.private_key` in tenant secrets is now unused by any cluster component
# (the OpenDKIM sidecar and infra-mail dkim-key-<tenant> Secrets were removed
# in step 2 PR-4). The field is kept in the secrets YAML for rollback safety.

# shellcheck source=../scripts/lib/platform.sh
source "${REPO_ROOT}/scripts/lib/platform.sh"

if [ -n "${SMTP_RELAY_HOST:-}" ] && [ -n "${SES_SMTP_ENDPOINT:-}" ]; then
    print_error "Both SES (ses.* in infra secrets) and mail.smtp_relay (infra config) are set for $MT_ENV; pick one outbound route"
    exit 1
fi

if [ -n "${SES_SMTP_ENDPOINT:-}" ] && [ -n "${SES_SMTP_USERNAME:-}" ] && [ -n "${SES_SMTP_PASSWORD:-}" ]; then
    # Reject endpoints with characters that could break out of the route
    # settings (newlines, quotes, ':'). Operator-controlled input; defense-in-depth.
    if ! [[ "$SES_SMTP_ENDPOINT" =~ ^[A-Za-z0-9.-]+$ ]]; then
        print_error "SES_SMTP_ENDPOINT '$SES_SMTP_ENDPOINT' contains invalid characters (allowed: A-Za-z0-9.-)"
        exit 1
    fi
    STALWART_SES_ENABLED=true
    export STALWART_V1_ROUTE="ses"
    print_status "Outbound relay: AWS SES ($SES_SMTP_ENDPOINT)"
elif [[ "${SMTP_RELAY_HOST:-}" == *.svc.cluster.local. ]] && mt_is_local_edge; then
    # Local-edge developer box only: mt_load_infra_config accepts a
    # cluster-local Service name solely on cluster.edge: local (the devbox's
    # Mailpit catch-all). Name and port are validated there, so they are
    # safe in the route spec. Plain SMTP inside the cluster; nothing leaves it.
    STALWART_SES_ENABLED=false
    SMTP_RELAY_NAMESPACE=$(cut -d. -f2 <<<"$SMTP_RELAY_HOST")
    # Already an absolute Service name: the route uses it as is.
    SMTP_RELAY_SVC_HOST="$SMTP_RELAY_HOST"
    export STALWART_V1_ROUTE="relay:${SMTP_RELAY_SVC_HOST}:${SMTP_RELAY_PORT}:false"
    print_status "Outbound relay: in-cluster catch-all ${SMTP_RELAY_HOST}:${SMTP_RELAY_PORT}"
elif [ -n "${SMTP_RELAY_HOST:-}" ]; then
    # Host/port were validated by mt_load_infra_config (mesh IP, numeric port),
    # so they are safe in the route spec.
    STALWART_SES_ENABLED=false
    # Stalwart 0.15 resolved a relay route's address only through DNS (no
    # IP-literal path), so a bare mesh IP failed every delivery with "record
    # not found"; v1 keeps the same cluster-local name. Give it a cluster-local name: a
    # selector-less Service whose only endpoint is the validated mesh IP
    # (applied below). The trailing dot makes the name absolute, so the pod's
    # DNS search list (ndots:5, node-inherited domains) can never resolve it
    # upstream; only cluster DNS answers, so the name maps to that IP alone.
    SMTP_RELAY_SVC_HOST="smtp-relay.${NS_MAIL}.svc.cluster.local."
    # The trailing `true` allows invalid certs: the hop is WireGuard-encrypted
    # and the relay's STARTTLS uses a self-signed cert. Safe ONLY because
    # mt_require_mesh_ip pins the host to 100.64.0.0/10 and the route name is
    # an absolute cluster-local name whose only endpoint is that IP: never
    # relax either (hostnames, a relative name) without turning it back off.
    export STALWART_V1_ROUTE="relay:${SMTP_RELAY_SVC_HOST}:${SMTP_RELAY_PORT}:true"
    print_status "Outbound relay: tailnet smart host ${SMTP_RELAY_HOST}:${SMTP_RELAY_PORT}"
else
    STALWART_SES_ENABLED=false
    export STALWART_V1_ROUTE="mx"
    print_status "Outbound relay: direct MX (no SES configured for this env)"
fi

# v1 pods read these at start; rotating any of them must roll the pods
# (stalwart-secrets is applied with plain kubectl apply, so the change
# tracker would not see it). The SES credentials are mounted as env vars and
# would otherwise roll silently on Secret-only changes.
export STALWART_SECRETS_CHECKSUM=$(printf '%s' "$STALWART_ADMIN_PASSWORD$STALWART_DB_PASSWORD$STALWART_OIDC_SECRET$S3_MAIL_ACCESS_KEY$S3_MAIL_SECRET_KEY${SES_SMTP_ENDPOINT:-}${SES_SMTP_USERNAME:-}${SES_SMTP_PASSWORD:-}" | sha256sum | cut -c1-16)

# Ensure namespace exists
print_status "Ensuring $NS_MAIL namespace exists..."
kubectl create namespace "$NS_MAIL" --dry-run=client -o yaml | kubectl apply -f -
print_success "Namespace ready: $NS_MAIL"

# =============================================================================
# Tailnet smart host Service (mail.smtp_relay only)
# =============================================================================
# The DNS name Stalwart's relay route points at (see the route block above).
if [ -n "${SMTP_RELAY_NAMESPACE:-}" ]; then
    # In-cluster catch-all: Stalwart resolves the Service itself; only open
    # egress to that namespace on the relay port.
    kubectl delete service smtp-relay -n "$NS_MAIL" --ignore-not-found=true >/dev/null
    kubectl delete endpointslice smtp-relay-tailnet -n "$NS_MAIL" --ignore-not-found=true >/dev/null
    print_status "Applying egress to ${SMTP_RELAY_NAMESPACE}:${SMTP_RELAY_PORT} for the in-cluster relay..."
    kubectl apply -f - <<EOF_RELAY
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-smtp-relay-egress
  namespace: ${NS_MAIL}
spec:
  podSelector:
    matchLabels:
      app: stalwart
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${SMTP_RELAY_NAMESPACE}
      ports:
        - port: ${SMTP_RELAY_PORT}
          protocol: TCP
EOF_RELAY
    print_success "In-cluster relay egress ready"
elif [ -n "${SMTP_RELAY_HOST:-}" ]; then
    print_status "Applying smtp-relay Service -> ${SMTP_RELAY_HOST}:${SMTP_RELAY_PORT}..."
    kubectl apply -f - <<EOF_RELAY
apiVersion: v1
kind: Service
metadata:
  name: smtp-relay
  namespace: ${NS_MAIL}
spec:
  type: ClusterIP
  ports:
    - name: smtp
      port: ${SMTP_RELAY_PORT}
      targetPort: ${SMTP_RELAY_PORT}
      protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: smtp-relay-tailnet
  namespace: ${NS_MAIL}
  labels:
    kubernetes.io/service-name: smtp-relay
    endpointslice.kubernetes.io/managed-by: mothertree-deploy-stalwart
addressType: IPv4
ports:
  - name: smtp
    port: ${SMTP_RELAY_PORT}
    protocol: TCP
endpoints:
  - addresses: ["${SMTP_RELAY_HOST}"]
---
# allow-mail-smtp-egress only opens 25/465/587. Open exactly the relay's
# address and port, for Stalwart only.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-smtp-relay-egress
  namespace: ${NS_MAIL}
spec:
  podSelector:
    matchLabels:
      app: stalwart
  policyTypes: [Egress]
  egress:
    - to:
        - ipBlock:
            cidr: ${SMTP_RELAY_HOST}/32
      ports:
        - port: ${SMTP_RELAY_PORT}
          protocol: TCP
EOF_RELAY
    print_success "smtp-relay Service ready"
else
    kubectl delete service smtp-relay -n "$NS_MAIL" --ignore-not-found=true >/dev/null
    kubectl delete endpointslice smtp-relay-tailnet -n "$NS_MAIL" --ignore-not-found=true >/dev/null
    kubectl delete networkpolicy allow-smtp-relay-egress -n "$NS_MAIL" --ignore-not-found=true >/dev/null
fi

# =============================================================================
# Clean up stale dkim-key Secret
# =============================================================================
# PR #353 created a dkim-key Secret here for Stalwart-side DKIM signing. That
# approach was abandoned — SES Easy DKIM handles outbound signing now (see the
# comment above). The Secret
# in the tenant namespace is no longer mounted by Stalwart. Delete any stale
# copy left over from a prior deploy. --ignore-not-found handles the benign
# "already gone" case; real failures (auth, connectivity) still surface.
kubectl delete secret dkim-key -n "$NS_MAIL" --ignore-not-found=true >/dev/null

# =============================================================================
# SES credentials Secret (tenant namespace, only when SES is configured)
# =============================================================================
# Write each value to a temp file and use --from-file so the username/password
# never appear in kubectl's argv (visible via ps on a shared CI host).
# No EXIT trap here — mt_deploy_start owns it for the deploy-end notification;
# `trap - EXIT` would clobber that. A leak on early failure is acceptable.
if [ "$STALWART_SES_ENABLED" = "true" ]; then
    print_status "Applying SES credentials Secret in $NS_MAIL..."
    SES_TMP_DIR=$(mktemp -d)
    printf '%s' "$SES_SMTP_ENDPOINT" > "$SES_TMP_DIR/endpoint"
    printf '%s' "$SES_SMTP_USERNAME" > "$SES_TMP_DIR/username"
    printf '%s' "$SES_SMTP_PASSWORD" > "$SES_TMP_DIR/password"
    kubectl create secret generic ses-credentials -n "$NS_MAIL" \
        --from-file=endpoint="$SES_TMP_DIR/endpoint" \
        --from-file=username="$SES_TMP_DIR/username" \
        --from-file=password="$SES_TMP_DIR/password" \
        --dry-run=client -o yaml | kubectl apply -f -
    rm -rf "$SES_TMP_DIR"
    print_success "SES credentials Secret applied"
else
    # Clear any stale Secret from a prior SES-enabled deploy. --ignore-not-found
    # handles the benign "already gone" case; stderr stays visible so real
    # failures (auth, connectivity) surface per the project's fail-fast rule.
    kubectl delete secret ses-credentials -n "$NS_MAIL" --ignore-not-found=true >/dev/null
fi

# =============================================================================
# Database Initialization
# =============================================================================
print_status "Initializing PostgreSQL database for Stalwart..."

# Copy the PostgreSQL admin secret from infra-db namespace
# This is needed for the db-init job to connect as postgres admin
print_status "Copying PostgreSQL admin secret to $NS_MAIL namespace..."

PG_PASSWORD=$(mt_pg_password)
if [ -z "$PG_PASSWORD" ]; then
    print_error "Could not retrieve postgres-credentials secret from $NS_DB namespace"
    exit 1
fi

kubectl create secret generic postgres-credentials \
    --namespace="$NS_MAIL" \
    --from-literal=postgres-password="$PG_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
print_success "PostgreSQL credentials copied"

# Which Stalwart the tenant runs now (v1 | v015 | none); decides below
# whether the 0.15 → v1 migration runs.
: "${S3_INTERNAL_ENDPOINT:?S3_INTERNAL_ENDPOINT not set by config.sh}"
source "${REPO_ROOT}/scripts/lib/stalwart-v1.sh"
STALWART_GENERATION=$(mt_stalwart_generation)

# A tenant still on 0.15 keeps the master-user secret its Deployment reads
# (secretKeyRef): a failed migration scales that 0.15 back up, and its pods
# would not start without the key. v1 has no master user, so v1 tenants
# drop it (removed explicitly below: client-side apply does not delete a key
# that disappears from stringData).
STALWART_MASTER_SECRET_LINE=""
if [ "$STALWART_GENERATION" = v015 ]; then
    # Password on stdin, never in argv (ps on a shared CI host).
    _master_hash=$(printf '%s\n' "$STALWART_ADMIN_PASSWORD" | openssl passwd -6 -salt "$(openssl rand -hex 8)" -stdin)
    STALWART_MASTER_SECRET_LINE="  STALWART_MASTER_SECRET: \"${_master_hash}\""
fi

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
${STALWART_MASTER_SECRET_LINE}
  S3_ACCESS_KEY: "$S3_MAIL_ACCESS_KEY"
  S3_SECRET_KEY: "$S3_MAIL_SECRET_KEY"
EOF
# Read first, outside a test, so a failed read stops the deploy (set -e).
_stale_master=$(kubectl get secret stalwart-secrets -n "$NS_MAIL" -o jsonpath='{.data.STALWART_MASTER_SECRET}')
if [ "$STALWART_GENERATION" != v015 ] && [ -n "$_stale_master" ]; then
    kubectl patch secret stalwart-secrets -n "$NS_MAIL" --type=json \
        -p '[{"op":"remove","path":"/data/STALWART_MASTER_SECRET"}]' >/dev/null
    print_status "Removed the 0.15 master-user secret from stalwart-secrets"
fi
unset _stale_master
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
envsubst '${NS_MAIL} ${STALWART_DB_NAME} ${STALWART_V1_DB_NAME} ${STALWART_DB_USER} ${PG_HOST}' \
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

# =============================================================================
# Redis for Stalwart v1 clustering (#715)
# =============================================================================
# Deployed ahead of the v1 cutover so it can bake; nothing uses it until then.
# Its own password (not the admin-portal Redis's): Stalwart v1 keeps the Redis
# URL in clear in its settings registry. Reused from the cluster when present,
# otherwise generated; it never needs to leave the cluster.
# Isolation depends on the mail namespace's ingress allow-list (which never
# opens 6379) plus the Stalwart-only Redis rule. create_env treats a failed
# deploy-network-policies.sh as non-fatal, so check here: without these, the
# Redis would be reachable from any pod in the cluster.
# allow-stalwart-mgmt-ingress is how the config plan Job (and the 0.15 dump
# Job) reach Stalwart's management port; without it they wait out their
# timeouts and the deploy fails late. prod was missing it before #715.
for _np in allow-mail-ingress allow-stalwart-redis-ingress allow-stalwart-mgmt-ingress; do
    if ! kubectl get networkpolicy "$_np" -n "$NS_MAIL" >/dev/null; then
        print_error "NetworkPolicy $_np missing in $NS_MAIL; run apps/deploy-network-policies.sh -e $MT_ENV -t $MT_TENANT first"
        exit 1
    fi
done
# Tell "no Secret yet" apart from an API error: regenerating on a transient
# read failure would leave Stalwart v1's stored Redis URL with a stale password.
if ! _redis_secret=$(kubectl get secret stalwart-redis -n "$NS_MAIL" -o name --ignore-not-found); then
    print_error "Could not read Secret stalwart-redis in $NS_MAIL"
    exit 1
fi
# Two passwords: REDIS_PASSWORD (Redis `default` user: probes, operators) and
# STALWART_PASSWORD (the restricted `stalwart` ACL user Stalwart connects as).
STALWART_REDIS_PASSWORD=""
STALWART_REDIS_USER_PASSWORD=""
if [ -n "$_redis_secret" ]; then
    STALWART_REDIS_PASSWORD=$(kubectl get secret stalwart-redis -n "$NS_MAIL" -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d)
    : "${STALWART_REDIS_PASSWORD:?Secret stalwart-redis in $NS_MAIL has no REDIS_PASSWORD}"
    STALWART_REDIS_USER_PASSWORD=$(kubectl get secret stalwart-redis -n "$NS_MAIL" -o jsonpath='{.data.STALWART_PASSWORD}' | base64 -d)
fi
# hex: safe inside a redis:// URL without percent-encoding
if [ -z "$STALWART_REDIS_PASSWORD" ]; then
    print_status "Generating Stalwart Redis password..."
    STALWART_REDIS_PASSWORD=$(openssl rand -hex 24)
fi
if [ -z "$STALWART_REDIS_USER_PASSWORD" ]; then
    print_status "Generating the Stalwart Redis ACL user's password..."
    STALWART_REDIS_USER_PASSWORD=$(openssl rand -hex 24)
fi
mt_reset_change_tracker
mt_apply kubectl apply -f <(kubectl create secret generic stalwart-redis -n "$NS_MAIL" \
    --from-literal=REDIS_PASSWORD="$STALWART_REDIS_PASSWORD" \
    --from-literal=STALWART_PASSWORD="$STALWART_REDIS_USER_PASSWORD" --dry-run=client -o yaml)
mt_apply kubectl apply -f <(envsubst '${NS_MAIL}' < "$REPO_ROOT/apps/manifests/stalwart/redis.yaml.tpl")
mt_restart_if_changed deployment/stalwart-redis -n "$NS_MAIL"
if ! kubectl rollout status deployment/stalwart-redis -n "$NS_MAIL" --timeout=120s; then
    print_error "stalwart-redis did not become ready"
    exit 1
fi
print_success "Stalwart Redis ready"

# =============================================================================
# Stalwart v1 (#715)
# =============================================================================
# v1 cannot open the 0.15 store, so a tenant still on 0.15 is migrated once
# (scripts/lib/stalwart-v1.sh): export from the running 0.15, stop it, copy
# and convert into STALWART_V1_DB_NAME, verify. The 0.15 database is only
# read, and any failure before v1 starts brings 0.15 back.
# STALWART_GENERATION was read before the stalwart-secrets apply above.
STALWART_FIRST_BOOT=""
case "$STALWART_GENERATION" in
    v1)
        print_status "Stalwart v1 already running; applying configuration"
        ;;
    none)
        print_status "No Stalwart yet; deploying v1 on an empty store"
        ;;
    v015)
        # Mail is down for the length of Job 2 (minutes); prod needs an
        # explicit go-ahead, a fresh pg_dump on the PG VM and a bucket
        # snapshot first (see the #715 runbook).
        if ! mt_is_dev_class && [ "${STALWART_MIGRATE_CONFIRM:-}" != "yes" ]; then
            print_error "Stalwart for $MT_TENANT is still 0.15 and must be migrated to v1 (#715)."
            print_error "This stops mail for a few minutes. Take a pg_dump of $STALWART_DB_NAME and an S3 snapshot,"
            print_error "then re-run with STALWART_MIGRATE_CONFIRM=yes."
            exit 1
        fi
        if ! mt_stalwart_v1_migrate; then
            exit 1
        fi
        STALWART_FIRST_BOOT=first-boot-after-migration
        ;;
esac
if ! mt_stalwart_v1_deploy $STALWART_FIRST_BOOT; then
    print_error "Stalwart v1 deployment failed"
    dump_pod_diagnostics "$NS_MAIL" "app=stalwart" || true
    exit 1
fi
print_success "Stalwart v1 deployed and configured"

# Apply public ingress for webmail
envsubst < "$REPO_ROOT/apps/manifests/stalwart/ingress.yaml.tpl" | kubectl apply -f -
print_success "Public ingress applied for $MAIL_HOST"

# Apply internal ingress for admin UI
envsubst < "$REPO_ROOT/apps/manifests/stalwart/ingress-internal.yaml.tpl" | kubectl apply -f -
print_success "Internal ingress applied for $WEBADMIN_HOST"

# =============================================================================
# Register tenant with Postfix for inbound mail routing
# =============================================================================
# Multi-tenant mail routing: Postfix receives inbound mail on port 25 and routes
# to the correct tenant's Stalwart based on recipient domain using transport_maps.
# Uses the shared configure-mail-routing script that scans ALL tenants to ensure
# consistent configuration whether running create_env or deploy-stalwart standalone.
# shellcheck source=../scripts/lib/platform.sh
source "${REPO_ROOT}/scripts/lib/platform.sh"
if mt_is_local_edge; then
    print_status "edge local: no inbound internet mail and no Postfix, skipping Postfix mail routing"
elif [ -x "$REPO_ROOT/scripts/configure-mail-routing" ]; then
    print_status "Configuring Postfix inbound mail routing for all tenants..."
    "$REPO_ROOT/scripts/configure-mail-routing" -e "$MT_ENV" --nesting-level=$((MT_NESTING_LEVEL+1)) 2>&1 | while read line; do
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
#   1. tcp-services ConfigMap entries (tells nginx where to proxy)
#   2. LB service ports (tells the cloud LB to forward to nginx's NodePort)
if mt_is_local_edge; then
    # Every tcp-services entry decodes PROXY protocol from the cloud load
    # balancer, which a devbox does not have; mail clients on the developer's
    # machine use kubectl port-forward instead (docs/devbox.md).
    print_status "edge local: no load balancer, skipping the nginx TCP proxy for tenant mail ports"
else
    print_status "Configuring nginx TCP proxy for tenant mail ports..."

    # Create tcp-services ConfigMap if it doesn't exist
    if ! kubectl get configmap tcp-services -n "$NS_INGRESS" >/dev/null 2>&1; then
        print_status "Creating tcp-services ConfigMap..."
        kubectl create configmap tcp-services -n "$NS_INGRESS"
    fi

    # Patch tcp-services ConfigMap with this tenant's port mappings
    print_status "Updating tcp-services ConfigMap for tenant $TENANT..."
    kubectl patch configmap tcp-services -n "$NS_INGRESS" --type merge -p "$(cat <<EOF
    {"data": {
      "${STALWART_SMTPS_PORT}": "${NS_MAIL}/stalwart:465:PROXY:",
      "${STALWART_SUBMISSION_PORT}": "${NS_MAIL}/stalwart:587:PROXY:",
      "${STALWART_IMAPS_PORT}": "${NS_MAIL}/stalwart:993:PROXY:",
      "${STALWART_IMAPS_APP_PORT}": "${NS_MAIL}/stalwart:994:PROXY:",
      "${STALWART_SUBMISSION_APP_PORT}": "${NS_MAIL}/stalwart:588:PROXY:"
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
fi

# =============================================================================
# CoreDNS rewrite: make mail.<tenant-domain> resolve to the in-cluster Stalwart
# service so authenticated submission from callers (Keycloak, Synapse, Impress,
# Nextcloud, portals) can connect with strict TLS verification. The external
# hostname is covered by the existing wildcard cert; the svc.cluster.local name
# is not. Without this rewrite, callers that verify TLS hostnames fail with a
# null-message exception (JavaMail, Twisted, Python smtplib) or fall back to
# skip-verify workarounds. See CHANGELOG / PR-2b for context.
#
# LKE exposes CoreDNS extension via the optional coredns-custom ConfigMap in
# kube-system, imported by the base Corefile via `import custom/*.include`.
# Each tenant owns its own key so concurrent deploys don't clash.
# =============================================================================
print_status "Ensuring CoreDNS rewrite for $MAIL_HOST → stalwart.$NS_MAIL.svc.cluster.local"
if ! kubectl -n kube-system get configmap coredns-custom >/dev/null 2>&1; then
    kubectl -n kube-system create configmap coredns-custom
fi
# shellcheck source=../scripts/lib/platform.sh
source "${REPO_ROOT}/scripts/lib/platform.sh"
_coredns_key="mail-${TENANT}.$(mt_coredns_custom_suffix)"   # .include on LKE, .override on k3s
_coredns_body="rewrite name ${MAIL_HOST} stalwart.${NS_MAIL}.svc.cluster.local"$'\n'

# Detect whether the desired rewrite is already in place. If so, the patch is
# a no-op and we can skip the (expensive) CoreDNS rollout below — the
# rewrite has been live and converged for some time already.
_coredns_existing=$(kubectl -n kube-system get configmap coredns-custom \
    -o "jsonpath={.data.${_coredns_key}}" 2>/dev/null || true)
# $(...) strips the trailing newline from the stored value, but
# _coredns_body ends with one. Compare without it, or the two never match and
# every deploy restarts CoreDNS (twice per pipeline: here and in the other
# rewrite script), which is a DNS blip for any pipeline testing at the time.
if [ "$_coredns_existing" = "${_coredns_body%$'\n'}" ]; then
    print_status "CoreDNS rewrite already in place — skipping patch + rollout"
    _coredns_changed=false
else
    # jq builds the JSON merge-patch so we don't hand-escape keys/values.
    _coredns_patch=$(jq -cn \
        --arg key "$_coredns_key" \
        --arg body "$_coredns_body" \
        '{data: {($key): $body}}')
    kubectl -n kube-system patch configmap coredns-custom --type=merge -p "$_coredns_patch"
    print_success "CoreDNS rewrite applied"
    _coredns_changed=true
fi

# -----------------------------------------------------------------------------
# When the rewrite changed, force a CoreDNS rollout instead of relying on the
# `reload` plugin. Background:
#
# CoreDNS's `reload` plugin watches the Corefile for changes (~30s poll), but
# the custom rewrites live in a separate `coredns-custom` ConfigMap that
# CoreDNS imports via `import custom/*.include`. Two compounding issues make
# the natural reload path racy:
#
#   1. Per-replica kubelet ConfigMap mount sync timing differs by node, so
#      one replica can serve the new rewrite while another still serves stale
#      — and the kube-dns service IP load-balances across both. The previous
#      probe (nslookup loop via the service IP, exit-on-first-success) masked
#      this completely: it'd pass on whichever replica converged first while
#      the other kept returning the public LB IP.
#   2. If NodeLocal DNS Cache is in the resolver path, it caches resolutions
#      per-node with its own positive TTL. CoreDNS being right doesn't help
#      until NodeLocal's cached entry expires.
#
# Cold-start audit (2026-05-14, gap #14) traced a deploy-stalwart success
# followed by an immediate provision-smtp SMTP smoke-test failure to exactly
# this race — the smoke-test pod resolved mail.<domain> to the LB IP (port
# 588 not exposed there) and hung past its 60s budget.
#
# Rollout-restart guarantees every replica has the new ConfigMap mounted and
# Corefile loaded before we proceed; bouncing node-local-dns (when present)
# flushes per-node caches. ~30-60s overhead per tenant; only paid when the
# rewrite actually changed.
# -----------------------------------------------------------------------------
if [ "$_coredns_changed" = "true" ]; then
    # Discover the CoreDNS deployment name via the standard k8s-app=kube-dns
    # label rather than hardcoding "coredns" — the deployment is named
    # "coredns" on most distros but some (e.g. legacy) use "kube-dns".
    _coredns_deploy=$(kubectl -n kube-system get deploy -l k8s-app=kube-dns -o name | head -n1)
    if [ -z "$_coredns_deploy" ]; then
        print_error "No CoreDNS deployment found in kube-system (label k8s-app=kube-dns)"
        exit 1
    fi
    print_status "Restarting $_coredns_deploy to propagate rewrite to all replicas"
    kubectl -n kube-system rollout restart "$_coredns_deploy"
    kubectl -n kube-system rollout status "$_coredns_deploy" --timeout=180s

    if kubectl -n kube-system get ds node-local-dns >/dev/null 2>&1; then
        print_status "Restarting node-local-dns DaemonSet to flush per-node caches"
        kubectl -n kube-system rollout restart ds/node-local-dns
        kubectl -n kube-system rollout status ds/node-local-dns --timeout=180s
    fi
fi

# -----------------------------------------------------------------------------
# Sanity check: after the rollout (or immediately, on a no-op), verify that
# the rewrite is actually live. We query EACH CoreDNS pod's ClusterIP
# directly (not via the kube-dns service IP) so a single laggy replica is
# detected rather than masked by load-balancing. busybox `nslookup` accepts
# a server as its second positional arg.
#
# The MAIL_HOST → ClusterIP mapping is the contract that downstream callers
# (provision-smtp's SMTP smoke test, Synapse, Docs, Files, portals) depend
# on. If even one CoreDNS replica is wrong, those callers can race against
# the wrong answer and hit the public LB IP (which does not expose 588).
# -----------------------------------------------------------------------------
print_status "Verifying CoreDNS rewrite propagated to ALL replicas"
_stalwart_cluster_ip=$(kubectl -n "$NS_MAIL" get svc stalwart -o jsonpath='{.spec.clusterIP}')
if [ -z "$_stalwart_cluster_ip" ]; then
    print_error "Could not read Stalwart ClusterIP from svc/stalwart in $NS_MAIL"
    exit 1
fi
# Explicit-verdict probe via a Job + post-completion logs (issue #623; shared
# with deploy-llm-webui.sh). The helper filters out Terminating CoreDNS pods
# (rollout-status returns once the new ReplicaSet is ready, but old pods can
# linger in `Running` for a few seconds — probing those IPs would burn the
# whole 90s budget on dead addresses). mt_coredns_rewrite_require aborts on
# 1 (definitely not converged) but WARNS and proceeds on 2 (no verdict) --
# "could not run the check" is not "the check failed" (#662). Safe here because
# the mail path has two fatal end-to-end backstops downstream: the SMTP smoke
# test in provision-smtp.js and submission gate #19, both of which exercise
# strictly more than this probe (DNS + NetworkPolicy + listener + TLS + SASL).
if ! mt_coredns_rewrite_require "$NS_MAIL" "$MAIL_HOST" "$_stalwart_cluster_ip"; then
    print_error "Check kube-system/coredns-custom ConfigMap and CoreDNS pod logs:"
    print_error "  kubectl -n kube-system get configmap coredns-custom -o yaml"
    print_error "  kubectl -n kube-system logs -l k8s-app=kube-dns --tail=100"
    exit 1
fi

# Wait for Deployment to be ready
print_status "Waiting for Stalwart Deployment to be ready..."
if kubectl rollout status deployment/stalwart -n "$NS_MAIL" --timeout=300s; then
    print_success "Stalwart Deployment is ready"
else
    # Fail loudly with a diagnostic dump so the next person sees the actual
    # reason instead of the downstream "Port-forward to Stalwart failed".
    # See gh#423 — pipeline #1329 timed out here, then exited 1 at the
    # port-forward block below with no pod-level evidence captured.
    print_error "Stalwart Deployment did not become Ready within 300s"
    echo ""
    print_error "=== Diagnostic dump (gh#423) ==="

    # dump_pod_diagnostics handles describe-pod + recent events; all kubectl
    # calls are guarded with `|| true` so a missing pod/secret doesn't short-
    # circuit later dumps. Reset error mode briefly for the same reason —
    # `set -euo pipefail` is active and we want every dump to fire.
    set +e

    dump_pod_diagnostics "$NS_MAIL" "app=stalwart"

    echo ""
    print_error "Diagnostics: deployment rollout state"
    kubectl get deployment stalwart -n "$NS_MAIL" -o wide || true
    kubectl describe deployment stalwart -n "$NS_MAIL" || true

    echo ""
    print_error "Diagnostics: stalwart pod logs (current, last 200 lines)"
    kubectl logs -n "$NS_MAIL" -l app=stalwart --tail=200 --all-containers=true || true

    echo ""
    print_error "Diagnostics: stalwart pod logs (previous, last 200 lines — if CrashLoop)"
    kubectl logs -n "$NS_MAIL" -l app=stalwart --previous --tail=200 --all-containers=true 2>/dev/null || \
        echo "  (no previous container — pod did not restart)"

    echo ""
    print_error "Diagnostics: TLS secret presence in mail namespace"
    # wildcard-tls-<tenant> is reflected from NS_MATRIX by emberstack/reflector
    # and is a mount-time dependency of the Stalwart pod. Missing/late =
    # ContainerCreating stall — a known hypothesis for the gh#423 cold-start
    # failure (deploy-dev-prep on #1329 logged "wildcard-tls not ready
    # after 120s" before continuing).
    # NEVER include `{.data}` here — this is a kubernetes.io/tls Secret whose
    # .data contains base64-encoded tls.key (the WILDCARD PRIVATE KEY). CI logs
    # on this public repo are not safe to leak even partial key material into.
    # The default tabular `get secret` output shows name/type/data-count only.
    kubectl get secret -n "$NS_MAIL" "wildcard-tls-${TENANT_NAME}" 2>&1 | head -3 || true
    kubectl get certificate -n "$NS_MATRIX" wildcard-tls -o wide 2>/dev/null || true

    set -e
    exit 1
fi

# The local domain is part of the v1 configuration plan (Domain object).

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
