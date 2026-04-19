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

mt_require_commands kubectl envsubst

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

# Generate SHA-512 crypt hash of admin password for master-user authentication
# Stalwart master.secret requires a hashed password (not plaintext)
export STALWART_MASTER_SECRET
STALWART_MASTER_SECRET=$(openssl passwd -6 -salt "$(openssl rand -hex 8)" "$STALWART_ADMIN_PASSWORD")
print_status "Master-user secret hash generated"

# =============================================================================
# Outbound mail path: SES relay (prod) or direct MX (dev)
# =============================================================================
# Stalwart signs outbound mail with the tenant's DKIM key (same key and selector
# infra-Postfix/OpenDKIM still uses for other callers during the PR-2/PR-3/PR-4
# transition). Receivers accepting multiple signatures is fine per RFC 6376.
#
# Route choice is environment-dependent:
#   - SES configured (prod): relay via AWS SES on 587 with SASL auth. The
#     ses-credentials Secret carries endpoint/username/password, mounted as
#     env vars referenced by %{env:...}% in the relay route block.
#   - SES unset (dev): direct MX delivery from the cluster's egress IP. No
#     smart host. Cluster egress IP has no PTR/SPF so receivers may tempfail,
#     but that matches the existing dev behavior (see project_mail_paths_per_env).

# Load tenant DKIM private key from tenant secrets YAML. Fail fast when mail is
# enabled but the key is missing — DKIM is load-bearing once Stalwart signs.
DKIM_PRIVATE_KEY=$(yq '.dkim.private_key' "$TENANT_SECRETS")
if [ -z "$DKIM_PRIVATE_KEY" ] || [ "$DKIM_PRIVATE_KEY" = "null" ]; then
    print_error "Missing '.dkim.private_key' in tenant secrets ($TENANT_SECRETS) — required for Stalwart DKIM signing."
    print_error "Generate with: openssl genrsa 2048"
    exit 1
fi

if [ -n "${SES_SMTP_ENDPOINT:-}" ] && [ -n "${SES_SMTP_USERNAME:-}" ] && [ -n "${SES_SMTP_PASSWORD:-}" ]; then
    # Reject endpoints containing characters that could inject TOML directives
    # via newlines. Operator-controlled input; defense-in-depth.
    if ! [[ "$SES_SMTP_ENDPOINT" =~ ^[A-Za-z0-9.-]+$ ]]; then
        print_error "SES_SMTP_ENDPOINT '$SES_SMTP_ENDPOINT' contains invalid characters (allowed: A-Za-z0-9.-)"
        exit 1
    fi
    STALWART_SES_ENABLED=true
    export STALWART_OUTBOUND_ROUTE_NAME="relay"
    export STALWART_OUTBOUND_ROUTE_TOML="    # Relay route - AWS SES via SASL-authenticated SMTP submission.
    [queue.route.\"relay\"]
    type = \"relay\"
    address = \"%{env:SES_SMTP_ENDPOINT}%\"
    port = 587
    protocol = \"smtp\"

    [queue.route.\"relay\".tls]
    implicit = false
    allow-invalid-certs = false

    [queue.route.\"relay\".auth]
    username = \"%{env:SES_SMTP_USER}%\"
    secret = \"%{env:SES_SMTP_PASSWORD}%\""
    print_status "Outbound relay: AWS SES ($SES_SMTP_ENDPOINT)"
else
    STALWART_SES_ENABLED=false
    export STALWART_OUTBOUND_ROUTE_NAME="mx"
    export STALWART_OUTBOUND_ROUTE_TOML="    # Direct MX delivery - no smart host configured for this env.
    [queue.route.\"mx\"]
    type = \"mx\"
    ip-lookup = \"ipv4_then_ipv6\""
    print_status "Outbound relay: direct MX (no SES configured for this env)"
fi

# Generate config checksum for pod annotations. Include every value the pod
# reads from a Secret/ConfigMap so rotating any of them forces a rollout.
# STALWART_OUTBOUND_ROUTE_TOML is baked into RENDERED_CONFIG below, but we hash
# DKIM key and SES creds separately because they are mounted (file or env) and
# would otherwise roll silently on Secret-only changes.
RENDERED_CONFIG=$(envsubst < "$REPO_ROOT/apps/manifests/stalwart/stalwart.yaml.tpl" 2>/dev/null || echo "")
export CONFIG_CHECKSUM=$(echo -n "$STALWART_ADMIN_PASSWORD$STALWART_DB_PASSWORD$S3_MAIL_ACCESS_KEY$DKIM_PRIVATE_KEY${SES_SMTP_ENDPOINT:-}${SES_SMTP_USERNAME:-}${SES_SMTP_PASSWORD:-}$RENDERED_CONFIG" | sha256sum | cut -d' ' -f1 | head -c 12)
print_status "Config checksum: $CONFIG_CHECKSUM"

# Ensure namespace exists
print_status "Ensuring $NS_MAIL namespace exists..."
kubectl create namespace "$NS_MAIL" --dry-run=client -o yaml | kubectl apply -f -
print_success "Namespace ready: $NS_MAIL"

# =============================================================================
# DKIM key Secret (tenant namespace)
# =============================================================================
# Stalwart reads the key via %{file:/opt/stalwart/dkim/dkim.private}%.
# Use stdin for the key contents so the PEM never appears in kubectl's argv.
print_status "Applying DKIM key Secret in $NS_MAIL..."
DKIM_TMP=$(mktemp)
trap 'rm -f "$DKIM_TMP"' EXIT
printf '%s' "$DKIM_PRIVATE_KEY" > "$DKIM_TMP"
kubectl create secret generic dkim-key -n "$NS_MAIL" \
    --from-file=dkim.private="$DKIM_TMP" \
    --dry-run=client -o yaml | kubectl apply -f -
rm -f "$DKIM_TMP"
trap - EXIT
print_success "DKIM key Secret applied"

# =============================================================================
# SES credentials Secret (tenant namespace, only when SES is configured)
# =============================================================================
if [ "$STALWART_SES_ENABLED" = "true" ]; then
    print_status "Applying SES credentials Secret in $NS_MAIL..."
    kubectl create secret generic ses-credentials -n "$NS_MAIL" \
        --from-literal=endpoint="$SES_SMTP_ENDPOINT" \
        --from-literal=username="$SES_SMTP_USERNAME" \
        --from-literal=password="$SES_SMTP_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    print_success "SES credentials Secret applied"
else
    # Clear any stale Secret from a prior SES-enabled deploy.
    kubectl delete secret ses-credentials -n "$NS_MAIL" --ignore-not-found=true >/dev/null 2>&1 || true
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

# Deploy HorizontalPodAutoscaler (HPA) for auto-scaling (only if min != max replicas)
if [ "$STALWART_MIN_REPLICAS" != "$STALWART_MAX_REPLICAS" ]; then
  print_status "Deploying HPA for Stalwart..."
  envsubst < "$REPO_ROOT/apps/manifests/stalwart/stalwart-hpa.yaml.tpl" | kubectl apply -f -
  print_success "Stalwart HPA deployed (CPU 80% threshold)"
else
  kubectl delete hpa stalwart-hpa -n "$NS_MAIL" --ignore-not-found >/dev/null 2>&1
  print_status "Stalwart: fixed replicas ($STALWART_MIN_REPLICAS), HPA removed"
fi

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
print_status "Configuring Postfix inbound mail routing for all tenants..."

if [ -x "$REPO_ROOT/scripts/configure-mail-routing" ]; then
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
# Stalwart treats all domains as external and recipient validation fails —
# all inbound mail is rejected. Essential for is_local_domain() to work.
print_status "Registering local domain $EMAIL_DOMAIN in Stalwart..."

# Use port-forward to call the API (Stalwart container doesn't have curl).
# API is on port 8080 (health listener, no TLS required).
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
