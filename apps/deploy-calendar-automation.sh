#!/bin/bash

# Deploy Calendar Automation Service using static Kubernetes manifests
# This script applies environment-specific manifests using envsubst
#
# Monitors user IMAP inboxes for iTIP calendar messages (REQUEST/REPLY/CANCEL)
# and automatically creates/updates/cancels events in Nextcloud CalDAV.
#
# Namespace structure:
#   - Calendar automation in NS_STALWART (shares namespace with Stalwart, e.g., 'tn-example-mail')
#
# Prerequisites:
#   - Stalwart Mail Server deployed and accessible
#   - Nextcloud deployed and accessible with CalDAV enabled
#   - calendar_enabled feature flag set to true in tenant config
#
# Usage:
#   ./apps/deploy-calendar-automation.sh -e dev -t example

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy Calendar Automation Service for a tenant."
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
mt_deploy_start "deploy-calendar-automation"

mt_require_commands kubectl envsubst

# Use the tenant mail namespace (same as Stalwart)
export NS_MAIL="$NS_STALWART"

print_status "Deploying Calendar Automation Service for environment: $MT_ENV"
print_status "Tenant: $TENANT"
print_status "Mail namespace: $NS_MAIL"

# Check if calendar_enabled feature flag is set
if [ "$CALENDAR_ENABLED" != "true" ]; then
    print_warning "Calendar not enabled for tenant $TENANT (features.calendar_enabled is not true)"
    print_warning "Skipping calendar automation deployment"
    exit 0
fi

# Check if mail is enabled (required for calendar automation — IMAP dependency)
if [ "$MAIL_ENABLED" != "true" ]; then
    print_error "Mail is not enabled for tenant $TENANT but calendar automation requires it."
    print_error "Enable 'features.mail_enabled' in tenant config first."
    exit 1
fi

# Check if files is enabled (required for CalDAV — Nextcloud dependency)
if [ "$FILES_ENABLED" != "true" ]; then
    print_error "Files (Nextcloud) is not enabled for tenant $TENANT but calendar automation requires it."
    print_error "Enable 'features.files_enabled' in tenant config first."
    exit 1
fi

print_status "Files host (CalDAV): $FILES_HOST"
print_status "Mail host (IMAP): $MAIL_HOST"

# Validate required secrets
if [ -z "$STALWART_ADMIN_PASSWORD" ] || [ "$STALWART_ADMIN_PASSWORD" = "null" ] || [[ "$STALWART_ADMIN_PASSWORD" == *"PLACEHOLDER"* ]]; then
    print_error "STALWART_ADMIN_PASSWORD not set. Deploy Stalwart first."
    exit 1
fi

# =============================================================================
# Retrieve Nextcloud admin credentials from K8s
# =============================================================================
# The Nextcloud Helm chart auto-generates admin credentials and stores them
# in a K8s Secret. We read them at deploy time to configure CalDAV access.
print_status "Reading Nextcloud admin credentials from cluster..."

export NEXTCLOUD_ADMIN_USER
NEXTCLOUD_ADMIN_USER=$(kubectl get secret nextcloud -n "$NS_FILES" -o jsonpath='{.data.nextcloud-username}' 2>/dev/null | base64 -d || echo "")
if [ -z "$NEXTCLOUD_ADMIN_USER" ]; then
    print_error "Could not read Nextcloud admin username from secret 'nextcloud' in $NS_FILES namespace"
    print_error "Is Nextcloud deployed? Run deploy-nextcloud.sh first."
    exit 1
fi

export NEXTCLOUD_ADMIN_PASSWORD
NEXTCLOUD_ADMIN_PASSWORD=$(kubectl get secret nextcloud -n "$NS_FILES" -o jsonpath='{.data.nextcloud-password}' 2>/dev/null | base64 -d || echo "")
if [ -z "$NEXTCLOUD_ADMIN_PASSWORD" ]; then
    print_error "Could not read Nextcloud admin password from secret 'nextcloud' in $NS_FILES namespace"
    print_error "Is Nextcloud deployed? Run deploy-nextcloud.sh first."
    exit 1
fi

print_status "Nextcloud admin user: $NEXTCLOUD_ADMIN_USER"

# =============================================================================
# Resource defaults for calendar automation
# =============================================================================
export CALENDAR_AUTOMATION_MEMORY_REQUEST="${CALENDAR_AUTOMATION_MEMORY_REQUEST:-64Mi}"
export CALENDAR_AUTOMATION_MEMORY_LIMIT="${CALENDAR_AUTOMATION_MEMORY_LIMIT:-128Mi}"
export CALENDAR_AUTOMATION_CPU_REQUEST="${CALENDAR_AUTOMATION_CPU_REQUEST:-50m}"
export POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-60}"

# Generate config checksum for pod annotations (triggers restart on config change)
RENDERED_CONFIG=$(envsubst < "$REPO_ROOT/apps/manifests/calendar-automation/deployment.yaml.tpl" 2>/dev/null || echo "")
APP_CODE_HASH=$(sha256sum "$REPO_ROOT/apps/calendar-automation/server.js" | cut -d' ' -f1 | head -c 12)
export CONFIG_CHECKSUM
CONFIG_CHECKSUM=$(echo -n "$STALWART_ADMIN_PASSWORD$NEXTCLOUD_ADMIN_PASSWORD$RENDERED_CONFIG$APP_CODE_HASH" | sha256sum | cut -d' ' -f1 | head -c 12)
print_status "Config checksum: $CONFIG_CHECKSUM"

# Ensure namespace exists (should already exist from Stalwart deployment)
print_status "Ensuring $NS_MAIL namespace exists..."
kubectl create namespace "$NS_MAIL" --dry-run=client -o yaml | kubectl apply -f -
print_success "Namespace ready: $NS_MAIL"

# =============================================================================
# Create ConfigMap with application code
# =============================================================================
# For v1, we mount the server.js as a ConfigMap (no Docker image build required).
# This allows rapid iteration without a CI pipeline.
# Future: build a Docker image and reference it directly in the Deployment.
print_status "Creating calendar automation application ConfigMap..."

kubectl create configmap calendar-automation-app \
    --namespace="$NS_MAIL" \
    --from-file=server.js="$REPO_ROOT/apps/calendar-automation/server.js" \
    --from-file=package.json="$REPO_ROOT/apps/calendar-automation/package.json" \
    --dry-run=client -o yaml | kubectl apply -f -
print_success "Application ConfigMap created"

# =============================================================================
# Install npm dependencies via init container approach
# =============================================================================
# The deployment uses node:22-alpine as base image with the app code mounted
# from a ConfigMap. We need an init container to install npm dependencies.
# For v1, we create a separate ConfigMap with an install script.
print_status "Creating npm install script ConfigMap..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: calendar-automation-install
  namespace: $NS_MAIL
data:
  install.sh: |
    #!/bin/sh
    set -e
    cp /app-src/package.json /app/package.json
    cp /app-src/server.js /app/server.js
    cd /app
    npm install --production 2>&1
    echo "Dependencies installed successfully"
EOF
print_success "Install script ConfigMap created"

# =============================================================================
# Create per-user CalDAV app passwords
# =============================================================================
# Nextcloud CalDAV is user-scoped — admin cannot access other users' calendars.
# We create a Nextcloud app password for each user via `occ`, allowing
# calendar-automation to authenticate as each user for CalDAV operations.
print_status "Creating per-user CalDAV app passwords..."

mt_require_commands jq

NEXTCLOUD_POD=$(kubectl get pods -n "$NS_FILES" -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$NEXTCLOUD_POD" ]; then
    print_warning "Nextcloud pod not found in $NS_FILES, skipping CalDAV token creation"
else
    # Ensure admin password matches K8s secret (may drift after Helm upgrades)
    kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
        env "OC_PASS=${NEXTCLOUD_ADMIN_PASSWORD}" php occ user:resetpassword --password-from-env admin 2>/dev/null || true

    # -------------------------------------------------------------------------
    # Provision Keycloak users into Nextcloud
    # -------------------------------------------------------------------------
    # Nextcloud only creates user principals on first OIDC web login. Users that
    # exist in Keycloak but have never logged into Nextcloud (e.g. CI mail users)
    # won't have CalDAV principals, so calendar-automation can't create calendars
    # for them. Pre-provision them here so CalDAV tokens can be created below.
    KC_TOKEN=""
    if [ -n "${KEYCLOAK_ADMIN_PASSWORD:-}" ] && [ -n "${AUTH_HOST:-}" ] && [ -n "${TENANT_KEYCLOAK_REALM:-}" ]; then
        KEYCLOAK_URL="https://${AUTH_HOST}"
        KC_TOKEN=$(curl -sf --connect-timeout 10 --max-time 15 -X POST \
          "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
          --data-urlencode "username=admin" \
          --data-urlencode "password=$KEYCLOAK_ADMIN_PASSWORD" \
          --data-urlencode "grant_type=password" \
          --data-urlencode "client_id=admin-cli" | \
          jq -r '.access_token // empty' 2>/dev/null) || true
    fi

    if [ -n "$KC_TOKEN" ]; then
        KC_EMAILS=$(curl -sf --connect-timeout 10 --max-time 15 \
          "$KEYCLOAK_URL/admin/realms/$TENANT_KEYCLOAK_REALM/users?max=500" \
          -H "Authorization: Bearer $KC_TOKEN" | \
          jq -r '.[] | select(.email != null) | .email' 2>/dev/null || echo "")

        NC_EXISTING=$(kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
            php occ user:list --output=json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || echo "")

        PROVISIONED=0
        while IFS= read -r kc_email; do
            [ -z "$kc_email" ] && continue
            # Validate email format (defense-in-depth against injection via crafted Keycloak data)
            if ! [[ "$kc_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$ ]]; then
                print_warning "Skipping invalid email from Keycloak: $kc_email"
                continue
            fi
            # Skip if already in Nextcloud
            if echo "$NC_EXISTING" | grep -qxF "$kc_email"; then
                continue
            fi
            # Provision with a random password (OIDC handles real auth)
            RAND_PASS=$(openssl rand -base64 32)
            kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
                env "OC_PASS=$RAND_PASS" \
                php occ user:add --password-from-env --display-name "$kc_email" -- "$kc_email" 2>/dev/null && \
                PROVISIONED=$((PROVISIONED + 1)) || \
                print_warning "Failed to provision Nextcloud user: $kc_email"
        done <<< "$KC_EMAILS"

        if [ "$PROVISIONED" -gt 0 ]; then
            print_success "Provisioned $PROVISIONED Keycloak user(s) into Nextcloud"
        fi
    else
        print_warning "Could not get Keycloak admin token — skipping user provisioning into Nextcloud"
    fi

    # Build combined user list: occ user:list (local users) + Keycloak emails (OIDC users).
    # occ user:list doesn't enumerate OIDC-backend users, so we merge both sources
    # to ensure CalDAV tokens are created for all users regardless of backend.
    NC_USER_JSON=$(kubectl exec -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
        php occ user:list --output=json 2>/dev/null || echo "{}")
    NC_EMAILS=$(echo "$NC_USER_JSON" | jq -r 'keys[] | select(. != "admin")' 2>/dev/null || echo "")
    USER_EMAILS_JSON=$(printf '%s\n%s' "$NC_EMAILS" "${KC_EMAILS:-}" | sort -u | grep -v '^$' | jq -R . | jq -s . || echo "[]")

    # Create app passwords in bulk via create-caldav-tokens.php.
    # This uses Nextcloud's ITokenProvider::generateToken() directly, bypassing
    # occ user:auth-tokens:add which requires allow_multiple_user_backends=1.
    # Single PHP process, single kubectl exec, ~30s for 550 users instead of ~6min.
    # Critically: allow_multiple_user_backends is never toggled, so the readiness
    # probe (oidc-health.php) is never poisoned and no NextcloudDown alert fires.
    CALDAV_TOKENS=$(echo "$USER_EMAILS_JSON" | kubectl exec -i -n "$NS_FILES" "$NEXTCLOUD_POD" -c nextcloud -- \
        su -s /bin/sh www-data -c 'php /var/www/html/create-caldav-tokens.php calendar-automation' 2>/dev/null || echo "{}")
    TOKEN_COUNT=$(echo "$CALDAV_TOKENS" | jq 'length' 2>/dev/null || echo "0")

    if [ "$TOKEN_COUNT" -eq 0 ]; then
        print_warning "No CalDAV tokens were created — calendar-automation will not be able to access user calendars"
    fi

    # Store tokens as a Secret (mounted read-only in the calendar-automation pod)
    kubectl create secret generic calendar-automation-caldav-tokens \
        --namespace="$NS_MAIL" \
        --from-literal=caldav-tokens.json="$CALDAV_TOKENS" \
        --dry-run=client -o yaml | kubectl apply -f -
    print_success "CalDAV app passwords created for $TOKEN_COUNT user(s)"
fi

# =============================================================================
# Apply deployment manifest
# =============================================================================
print_status "Applying calendar automation manifests..."

# Use explicit variable list for envsubst to avoid substituting unintended variables
envsubst '${NS_MAIL} ${NS_FILES} ${TENANT_NAME} ${FILES_HOST} ${NEXTCLOUD_ADMIN_USER} ${NEXTCLOUD_ADMIN_PASSWORD} ${STALWART_ADMIN_PASSWORD} ${CALENDAR_AUTOMATION_MEMORY_REQUEST} ${CALENDAR_AUTOMATION_MEMORY_LIMIT} ${CALENDAR_AUTOMATION_CPU_REQUEST} ${POLL_INTERVAL_SECONDS} ${CONFIG_CHECKSUM}' \
    < "$REPO_ROOT/apps/manifests/calendar-automation/deployment.yaml.tpl" | kubectl apply -f -
print_success "Calendar Automation Deployment and Service applied"

# =============================================================================
# Patch deployment to add init container for npm install
# =============================================================================
# The deployment template uses a ConfigMap volume for the app code.
# We need an init container that copies the code and installs dependencies
# into an emptyDir volume shared with the main container.
print_status "Patching deployment with init container for npm dependencies..."

kubectl patch deployment calendar-automation -n "$NS_MAIL" --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/initContainers",
    "value": [
      {
        "name": "npm-install",
        "image": "node:22-alpine",
        "command": ["sh", "/install/install.sh"],
        "env": [
          {"name": "HOME", "value": "/app"},
          {"name": "npm_config_cache", "value": "/app/.npm-cache"}
        ],
        "securityContext": {
          "allowPrivilegeEscalation": false,
          "capabilities": {"drop": ["ALL"]},
          "runAsNonRoot": true,
          "runAsUser": 1001
        },
        "volumeMounts": [
          {"name": "app-src", "mountPath": "/app-src", "readOnly": true},
          {"name": "app", "mountPath": "/app"},
          {"name": "install-script", "mountPath": "/install", "readOnly": true}
        ]
      }
    ]
  },
  {
    "op": "replace",
    "path": "/spec/template/spec/volumes",
    "value": [
      {"name": "app-src", "configMap": {"name": "calendar-automation-app"}},
      {"name": "app", "emptyDir": {}},
      {"name": "install-script", "configMap": {"name": "calendar-automation-install", "defaultMode": 493}},
      {"name": "caldav-tokens", "secret": {"secretName": "calendar-automation-caldav-tokens", "optional": true}}
    ]
  },
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/volumeMounts",
    "value": [
      {"name": "app", "mountPath": "/app", "readOnly": false},
      {"name": "caldav-tokens", "mountPath": "/config", "readOnly": true}
    ]
  }
]'
print_success "Init container patched"

# Wait for Deployment to be ready
print_status "Waiting for Calendar Automation Deployment to be ready..."
if kubectl rollout status deployment/calendar-automation -n "$NS_MAIL" --timeout=180s; then
    print_success "Calendar Automation Deployment is ready"
else
    print_warning "Calendar Automation Deployment may not be fully ready"
    print_status "Check logs with: kubectl logs -n $NS_MAIL -l app=calendar-automation"
fi

print_success "Calendar Automation Service deployed successfully for $MT_ENV environment"
echo ""
print_status "Namespace: $NS_MAIL"
print_status "CalDAV target: https://${FILES_HOST}/remote.php/dav"
print_status "IMAP source: stalwart.${NS_MAIL}.svc.cluster.local:993 (master-user auth)"
print_status "Polling interval: ${POLL_INTERVAL_SECONDS}s"
echo ""
print_status "The service will:"
print_status "  - Monitor all user inboxes for calendar invites (iTIP messages)"
print_status "  - Auto-create tentative calendar entries for new invitations (REQUEST)"
print_status "  - Update attendee status for REPLY messages"
print_status "  - Remove/cancel events for CANCEL messages"
echo ""
print_status "To check status: kubectl get pods -n $NS_MAIL -l app=calendar-automation"
print_status "To view logs: kubectl logs -n $NS_MAIL -l app=calendar-automation -f"
print_status "To view metrics: kubectl port-forward -n $NS_MAIL deploy/calendar-automation 8080:8080 && curl localhost:8080/metrics"
