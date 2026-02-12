#!/bin/bash
#
# Deploy Matrix Alertmanager for AlertManager -> Matrix room notifications
#
# This script:
# 1. Validates required environment variables
# 2. Generates configuration and manifests
# 3. Deploys the matrix-alertmanager service
#
# Required environment variables:
#   MT_ENV - Environment (prod, dev)
#
# Optional environment variables:
#   TENANT                           - Tenant name (default: example)
#   MATRIX_HOST                      - Matrix homeserver hostname (loaded from tenant config if not set)
#   MATRIX_HOMESERVER                - Matrix homeserver URL (derived from MATRIX_HOST if not set)
#   MATRIX_ALERTMANAGER_ACCESS_TOKEN - Matrix access token (loaded from tenant secrets if not set)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-/workspace}"
MANIFESTS_DIR="$REPO/apps/manifests/alerting"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Check required environment
if [ -z "${MT_ENV:-}" ]; then
  log_error "MT_ENV is not set. Usage: MT_ENV=prod ./deploy-alerting.sh"
  exit 1
fi

log_info "Deploying alerting components for environment: $MT_ENV"

# Standalone mode: load config from tenant files when not called from create_env
TENANT="${TENANT:-example}"
TENANT_CONFIG="$REPO/tenants/$TENANT/$MT_ENV.config.yaml"
TENANT_SECRETS="$REPO/tenants/$TENANT/$MT_ENV.secrets.yaml"

if [ -z "${MATRIX_HOST:-}" ]; then
    log_info "MATRIX_HOST not set, loading from tenant config ($TENANT)..."
    if [ ! -f "$TENANT_CONFIG" ]; then
      log_error "Tenant config not found: $TENANT_CONFIG"
      exit 1
    fi
    TENANT_ENV_DNS_LABEL=$(yq '.dns.env_dns_label // ""' "$TENANT_CONFIG")
    TENANT_DOMAIN=$(yq '.dns.domain' "$TENANT_CONFIG")
    if [ -n "$TENANT_ENV_DNS_LABEL" ] && [ "$TENANT_ENV_DNS_LABEL" != "null" ]; then
      MATRIX_HOST="matrix.${TENANT_ENV_DNS_LABEL}.${TENANT_DOMAIN}"
    else
      MATRIX_HOST="matrix.${TENANT_DOMAIN}"
    fi
    log_info "Derived MATRIX_HOST=$MATRIX_HOST"
fi

if [ -z "${MATRIX_ALERTMANAGER_ACCESS_TOKEN:-}" ]; then
    if [ -f "$TENANT_SECRETS" ]; then
      MATRIX_ALERTMANAGER_ACCESS_TOKEN=$(yq '.alertbot.access_token // ""' "$TENANT_SECRETS")
      if [ -n "$MATRIX_ALERTMANAGER_ACCESS_TOKEN" ] && [ "$MATRIX_ALERTMANAGER_ACCESS_TOKEN" != "null" ]; then
        log_info "Loaded alertbot access token from tenant secrets"
      else
        MATRIX_ALERTMANAGER_ACCESS_TOKEN=""
      fi
    fi
fi
MATRIX_HOMESERVER="${MATRIX_HOMESERVER:-https://$MATRIX_HOST}"
MATRIX_SERVER_NAME="$MATRIX_HOST"

# Check for Matrix access token
if [ -z "${MATRIX_ALERTMANAGER_ACCESS_TOKEN:-}" ]; then
  log_warn "MATRIX_ALERTMANAGER_ACCESS_TOKEN is not set"
  log_warn "Matrix notifications will not work until you:"
  log_warn "  1. Create an alertbot user on Matrix"
  log_warn "  2. Get an access token for that user"
  log_warn "  3. Set MATRIX_ALERTMANAGER_ACCESS_TOKEN in your secrets file"
  log_warn "Skipping matrix-alertmanager deployment for now..."
  exit 0
fi

log_info "Using Matrix homeserver: $MATRIX_HOMESERVER"
log_info "Using Matrix user: @alertbot:$MATRIX_SERVER_NAME"

# Generate the config YAML
# Note: Room IDs are specified in AlertManager webhook URLs, not here
CONFIG_YAML=$(cat <<EOF
# HTTP server configuration
http:
  address: ""
  port: 3000
  alerts-path-prefix: /alerts
  metrics-path: /metrics
  metrics-enabled: true

# Matrix connection configuration
matrix:
  homeserver-url: ${MATRIX_HOMESERVER}
  user-id: "@alertbot:${MATRIX_SERVER_NAME}"
  access-token: "${MATRIX_ALERTMANAGER_ACCESS_TOKEN}"

# Templating configuration
templating:
  firing-template: |
    <p>
    <strong><font color="red">🔥 FIRING</font></strong><br/>
    <strong>Alert:</strong> {{ .Alert.Labels.alertname }}<br/>
    <strong>Severity:</strong> {{ .Alert.Labels.severity }}<br/>
    {{ if .Alert.Annotations.summary }}<strong>Summary:</strong> {{ .Alert.Annotations.summary }}<br/>{{ end }}
    {{ if .Alert.Annotations.description }}<strong>Description:</strong> {{ .Alert.Annotations.description }}<br/>{{ end }}
    {{ if .Alert.Labels.namespace }}<strong>Namespace:</strong> {{ .Alert.Labels.namespace }}<br/>{{ end }}
    </p>
  resolved-template: |
    <p>
    <strong><font color="green">✅ RESOLVED</font></strong><br/>
    <strong>Alert:</strong> {{ .Alert.Labels.alertname }}<br/>
    <strong>Severity:</strong> {{ .Alert.Labels.severity }}<br/>
    {{ if .Alert.Annotations.summary }}<strong>Summary:</strong> {{ .Alert.Annotations.summary }}{{ end }}
    </p>
EOF
)

# Create temp directory for generated manifests
GENERATED_DIR=$(mktemp -d)
trap 'rm -rf "$GENERATED_DIR"' EXIT

# Ensure monitoring namespace exists
kubectl get namespace infra-monitoring >/dev/null 2>&1 || kubectl create namespace infra-monitoring

# Create the secret with the config file
log_info "Creating matrix-alertmanager config secret..."
kubectl create secret generic matrix-alertmanager-config \
  --namespace=infra-monitoring \
  --from-literal=config.yaml="$CONFIG_YAML" \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy the service (static, no templating needed)
log_info "Deploying matrix-alertmanager service..."
kubectl apply -f "$MANIFESTS_DIR/matrix-alertmanager-service.yaml"

# Generate and deploy the deployment
log_info "Deploying matrix-alertmanager deployment..."
envsubst < "$MANIFESTS_DIR/matrix-alertmanager-deployment.yaml.tpl" > "$GENERATED_DIR/deployment.yaml"
kubectl apply -f "$GENERATED_DIR/deployment.yaml"

# Restart deployment to pick up any config changes
log_info "Restarting matrix-alertmanager to pick up config changes..."
kubectl rollout restart deployment/matrix-alertmanager -n infra-monitoring 2>/dev/null || true

# Wait for deployment to be ready
log_info "Waiting for matrix-alertmanager to be ready..."
if kubectl rollout status deployment/matrix-alertmanager -n infra-monitoring --timeout=120s; then
  log_success "matrix-alertmanager deployed successfully"
else
  log_warn "matrix-alertmanager deployment may not be ready yet"
  log_info "Check logs: kubectl logs -n infra-monitoring -l app=matrix-alertmanager"
fi

# Show status
log_info "Deployment status:"
kubectl get pods -n infra-monitoring -l app=matrix-alertmanager

log_success "Alerting deployment complete for $MT_ENV"
echo ""
log_info "Next steps:"
echo "  1. Ensure the alertbot user (@alertbot:$MATRIX_SERVER_NAME) is invited to the alerts room"
echo "  2. Room ID is configured in apps/environments/$MT_ENV/prometheus.yaml"
echo "  3. Run 'helmfile -e $MT_ENV -l name=kube-prometheus-stack apply' to update AlertManager config"
echo "  4. Monitor logs: kubectl logs -n infra-monitoring -l app=matrix-alertmanager"
