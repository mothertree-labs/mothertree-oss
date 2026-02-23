#!/bin/bash
#
# Deploy Matrix Alertmanager for AlertManager -> Matrix room notifications
#
# This script:
# 1. Loads tenant config (Matrix host, access token, etc.)
# 2. Generates configuration and manifests
# 3. Deploys the matrix-alertmanager service
#
# Usage:
#   ./apps/scripts/deploy-alerting.sh -e prod -t example

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
    echo "Usage: $0 -e <env> -t <tenant>"
    echo ""
    echo "Deploy matrix-alertmanager (AlertManager -> Matrix room notifications)."
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

mt_require_commands kubectl envsubst

MANIFESTS_DIR="$REPO_ROOT/apps/manifests/alerting"

# Allow alertbot to use a different homeserver (e.g., dev alerts sent to prod Matrix)
if [ -n "${ALERTBOT_MATRIX_HOMESERVER:-}" ]; then
  MATRIX_HOMESERVER="$ALERTBOT_MATRIX_HOMESERVER"
  # Derive user-id from the override homeserver hostname
  ALERTBOT_HOST="${MATRIX_HOMESERVER#https://}"
  ALERTBOT_USER_ID="@alertbot:${ALERTBOT_HOST#matrix.}"
else
  MATRIX_HOMESERVER="https://$MATRIX_HOST"
  ALERTBOT_USER_ID="@alertbot:$MATRIX_HOST"
fi

# Check for Matrix access token
if [ -z "${MATRIX_ALERTMANAGER_ACCESS_TOKEN:-}" ]; then
  print_warning "MATRIX_ALERTMANAGER_ACCESS_TOKEN is not set"
  print_warning "Matrix notifications will not work until you:"
  print_warning "  1. Create an alertbot user on Matrix"
  print_warning "  2. Get an access token for that user"
  print_warning "  3. Set alertbot.access_token in your tenant secrets file"
  print_warning "Skipping matrix-alertmanager deployment for now..."
  exit 0
fi

print_status "Deploying alerting components for environment: $MT_ENV"
print_status "Using Matrix homeserver: $MATRIX_HOMESERVER"
print_status "Using Matrix user: $ALERTBOT_USER_ID"

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
  user-id: "${ALERTBOT_USER_ID}"
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
kubectl get namespace "$NS_MONITORING" >/dev/null 2>&1 || kubectl create namespace "$NS_MONITORING"

# Create the secret with the config file
print_status "Creating matrix-alertmanager config secret..."
kubectl create secret generic matrix-alertmanager-config \
  --namespace="$NS_MONITORING" \
  --from-literal=config.yaml="$CONFIG_YAML" \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy the service (static, no templating needed)
print_status "Deploying matrix-alertmanager service..."
kubectl apply -f "$MANIFESTS_DIR/matrix-alertmanager-service.yaml"

# Generate and deploy the deployment
print_status "Deploying matrix-alertmanager deployment..."
envsubst < "$MANIFESTS_DIR/matrix-alertmanager-deployment.yaml.tpl" > "$GENERATED_DIR/deployment.yaml"
kubectl apply -f "$GENERATED_DIR/deployment.yaml"

# Restart deployment to pick up any config changes
print_status "Restarting matrix-alertmanager to pick up config changes..."
kubectl rollout restart deployment/matrix-alertmanager -n "$NS_MONITORING" 2>/dev/null || true

# Wait for deployment to be ready
print_status "Waiting for matrix-alertmanager to be ready..."
if kubectl rollout status deployment/matrix-alertmanager -n "$NS_MONITORING" --timeout=120s; then
  print_success "matrix-alertmanager deployed successfully"
else
  print_warning "matrix-alertmanager deployment may not be ready yet"
  print_status "Check logs: kubectl logs -n $NS_MONITORING -l app=matrix-alertmanager"
fi

# Show status
print_status "Deployment status:"
kubectl get pods -n "$NS_MONITORING" -l app=matrix-alertmanager

print_success "Alerting deployment complete for $MT_ENV"
echo ""
print_status "Next steps:"
echo "  1. Ensure the alertbot user ($ALERTBOT_USER_ID) is invited to the alerts room AND the deploy room"
echo "  2. Alerts room ID is configured in apps/environments/$MT_ENV/prometheus.yaml"
echo "     Deploy room ID is configured in tenant secrets (alertbot.deploy_room_id)"
echo "  3. Run 'helmfile -e $MT_ENV -l name=kube-prometheus-stack apply' to update AlertManager config"
echo "  4. Monitor logs: kubectl logs -n $NS_MONITORING -l app=matrix-alertmanager"
