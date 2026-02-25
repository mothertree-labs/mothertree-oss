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
export CALENDAR_AUTOMATION_CPU_REQUEST="${CALENDAR_AUTOMATION_CPU_REQUEST:-10m}"
export CALENDAR_AUTOMATION_CPU_LIMIT="${CALENDAR_AUTOMATION_CPU_LIMIT:-100m}"
export POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-60}"

# Generate config checksum for pod annotations (triggers restart on config change)
RENDERED_CONFIG=$(envsubst < "$REPO_ROOT/apps/manifests/calendar-automation/deployment.yaml.tpl" 2>/dev/null || echo "")
export CONFIG_CHECKSUM
CONFIG_CHECKSUM=$(echo -n "$STALWART_ADMIN_PASSWORD$NEXTCLOUD_ADMIN_PASSWORD$RENDERED_CONFIG" | sha256sum | cut -d' ' -f1 | head -c 12)
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

cat <<'INSTALL_EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: calendar-automation-install
  namespace: NS_MAIL_PLACEHOLDER
data:
  install.sh: |
    #!/bin/sh
    set -e
    cp /app-src/package.json /app/package.json
    cp /app-src/server.js /app/server.js
    cd /app
    npm install --production 2>&1
    echo "Dependencies installed successfully"
INSTALL_EOF

# Patch the namespace (envsubst can't be used on heredoc with single quotes)
kubectl get configmap calendar-automation-install -n "$NS_MAIL" >/dev/null 2>&1 && \
    kubectl delete configmap calendar-automation-install -n "$NS_MAIL" --ignore-not-found >/dev/null

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
# Apply deployment manifest
# =============================================================================
print_status "Applying calendar automation manifests..."

# Use explicit variable list for envsubst to avoid substituting unintended variables
envsubst '${NS_MAIL} ${TENANT_NAME} ${FILES_HOST} ${NEXTCLOUD_ADMIN_USER} ${NEXTCLOUD_ADMIN_PASSWORD} ${STALWART_ADMIN_PASSWORD} ${CALENDAR_AUTOMATION_MEMORY_REQUEST} ${CALENDAR_AUTOMATION_MEMORY_LIMIT} ${CALENDAR_AUTOMATION_CPU_REQUEST} ${CALENDAR_AUTOMATION_CPU_LIMIT} ${POLL_INTERVAL_SECONDS} ${CONFIG_CHECKSUM}' \
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
      {"name": "install-script", "configMap": {"name": "calendar-automation-install", "defaultMode": 493}}
    ]
  },
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/volumeMounts",
    "value": [
      {"name": "app", "mountPath": "/app", "readOnly": false}
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
print_status "IMAP source: stalwart.${NS_MAIL}.svc.cluster.local:993"
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
