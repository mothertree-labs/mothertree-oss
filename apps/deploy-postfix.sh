#!/bin/bash

# Deploy Postfix K8s Resources
# Purpose: Deploy Postfix SMTP server with OpenDKIM + Tailscale sidecars to infra-mail namespace
#
# Creates:
#   - ServiceAccount + RBAC (for Tailscale state Secret management)
#   - ConfigMaps (postfix-config, opendkim-config, postfix-init-scripts)
#   - Secrets (Tailscale auth key)
#   - Deployment (Postfix + OpenDKIM sidecar + Tailscale sidecar + prepare-routing init container)
#   - Services (ClusterIP port 25, NodePort 30025, ClusterIP port 587)
#   - NetworkPolicy
#
# Called by: deploy_infra (before configure-mail-routing)
# Can also be run standalone.
#
# Usage:
#   ./apps/deploy-postfix.sh -e <env>
#
# Examples:
#   ./apps/deploy-postfix.sh -e dev
#   ./apps/deploy-postfix.sh -e prod

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  echo "Usage: $0 -e <env>"
  echo ""
  echo "Deploy Postfix SMTP server to infra-mail namespace."
  echo ""
  echo "Options:"
  echo "  -e <env>       Environment (e.g., dev, prod)"
  echo "  -h, --help     Show this help"
}

mt_parse_args "$@"
mt_require_env

# Load infrastructure configuration (sets SMTP_DOMAIN, NS_MAIL, etc.)
source "${REPO_ROOT}/scripts/lib/infra-config.sh"
mt_load_infra_config

mt_require_commands kubectl envsubst shasum

MANIFESTS_DIR="$REPO_ROOT/apps/manifests/postfix"

# =============================================================================
# Load Postfix-specific config
# =============================================================================

# Required: Postfix relay VM Tailscale IP
: "${POSTFIX_RELAY_IP:?POSTFIX_RELAY_IP not set. Add postfix_relay.tailscale_ip to infra config.}"
export POSTFIX_RELAY_IP

# Required: Headscale URL (for Tailscale sidecar)
: "${HEADSCALE_URL:?HEADSCALE_URL not set. Add headscale.url to infra config.}"
export HEADSCALE_URL

# Required: Tailscale pre-auth key (from infra secrets)
: "${TAILSCALE_AUTHKEY:?TAILSCALE_AUTHKEY not set. Add tailscale.authkey to infra secrets.}"

# =============================================================================
# Compute derived variables
# =============================================================================

# Postfix uses "relay" hostname to avoid conflicts with tenant Stalwart servers
# Tenant Stalwarts use "mail.<domain>" as their hostname for user-facing SMTP
export SMTP_HOSTNAME="relay.${SMTP_DOMAIN}"

export DKIM_SELECTOR="default"

# SECURITY: Trusted relay networks for K8s Postfix
# Components:
#   - 127.0.0.0/8: localhost
#   - 10.0.0.0/8: K8s pod network (Cilium)
#   - 172.16.0.0/12: K8s service network
#   - Postfix relay VM's Tailscale IP: allows relay to submit mail back to K8s Postfix
# Do NOT trust the entire 100.64.0.0/10 — that would let any Tailscale peer relay mail.
export POSTFIX_MYNETWORKS="127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,${POSTFIX_RELAY_IP}/32"

# Compute SMTP_ALLOWED_SENDER_DOMAINS from tenant configs if not already set
if [ -z "${SMTP_ALLOWED_SENDER_DOMAINS:-}" ]; then
  source "${REPO_ROOT}/scripts/lib/paths.sh"
  _mt_resolve_tenants_dir

  SMTP_ALLOWED_SENDER_DOMAINS=""
  for tenant_dir in "$MT_TENANTS_DIR"/*/; do
    config_file="$tenant_dir/${MT_ENV}.config.yaml"
    if [ -f "$config_file" ]; then
      base_domain=$(yq '.dns.domain' "$config_file")
      env_label=$(yq '.dns.env_dns_label // ""' "$config_file")
      if [ -n "$env_label" ] && [ "$env_label" != "null" ]; then
        domain="${env_label}.${base_domain}"
      else
        domain="$base_domain"
      fi
      if [ -n "$domain" ] && [ "$domain" != "null" ]; then
        SMTP_ALLOWED_SENDER_DOMAINS="${SMTP_ALLOWED_SENDER_DOMAINS:+$SMTP_ALLOWED_SENDER_DOMAINS,}$domain"
      fi
    fi
  done
fi
export SMTP_ALLOWED_SENDER_DOMAINS

print_status "Deploying Postfix to $NS_MAIL (env: $MT_ENV)"
print_status "  SMTP domain: $SMTP_DOMAIN"
print_status "  SMTP hostname: $SMTP_HOSTNAME"
print_status "  Relay VM (Tailscale): $POSTFIX_RELAY_IP"
print_status "  Headscale URL: $HEADSCALE_URL"
print_status "  Trusted networks: $POSTFIX_MYNETWORKS"
print_status "  Allowed sender domains: ${SMTP_ALLOWED_SENDER_DOMAINS:-<none>}"

# =============================================================================
# Process config templates
# =============================================================================

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

# Process Postfix main.cf template
# Only substitute our variables — leave Postfix $variables (e.g. $myhostname) intact
envsubst '${SMTP_HOSTNAME} ${SMTP_DOMAIN} ${POSTFIX_MYNETWORKS} ${POSTFIX_RELAY_IP}' \
  < "$MANIFESTS_DIR/postfix-main.cf.tpl" > "$WORK_DIR/main.cf"

# Process aliases template
envsubst '${SMTP_DOMAIN}' \
  < "$MANIFESTS_DIR/postfix-aliases.tpl" > "$WORK_DIR/aliases"

# Process OpenDKIM config template
envsubst '${SMTP_DOMAIN} ${DKIM_SELECTOR}' \
  < "$MANIFESTS_DIR/opendkim.conf.tpl" > "$WORK_DIR/opendkim.conf"

# Create TrustedHosts file
cat > "$WORK_DIR/TrustedHosts" <<'EOF'
127.0.0.1
localhost
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
EOF

# =============================================================================
# Compute config checksums for deployment annotations
# =============================================================================

CHECKSUM_POSTFIX_CONFIG=$(cat "$WORK_DIR/main.cf" "$MANIFESTS_DIR/postfix-master.cf" "$WORK_DIR/aliases" | shasum -a 256 | cut -d' ' -f1)
CHECKSUM_OPENDKIM_CONFIG=$(cat "$WORK_DIR/opendkim.conf" "$WORK_DIR/TrustedHosts" | shasum -a 256 | cut -d' ' -f1)
CHECKSUM_INIT_SCRIPTS=$(shasum -a 256 "$MANIFESTS_DIR/10-master-cf-overrides.sh" | cut -d' ' -f1)

export CHECKSUM_POSTFIX_CONFIG CHECKSUM_OPENDKIM_CONFIG CHECKSUM_INIT_SCRIPTS

# =============================================================================
# Apply RBAC (ServiceAccount, Role, RoleBinding for Tailscale state Secrets)
# =============================================================================

print_status "Applying Postfix RBAC..."
mt_reset_change_tracker
envsubst '${NS_MAIL}' < "$MANIFESTS_DIR/postfix-rbac.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Apply Tailscale auth Secret
# =============================================================================

print_status "Applying Postfix Tailscale auth Secret..."
kubectl create secret generic postfix-tailscale-auth -n "$NS_MAIL" \
  --from-literal=TS_AUTHKEY="$TAILSCALE_AUTHKEY" \
  --dry-run=client -o yaml | mt_apply kubectl apply -f -

# =============================================================================
# Create/update ConfigMaps
# =============================================================================

# Postfix config ConfigMap (main.cf, master.cf, aliases)
print_status "Applying postfix-config ConfigMap..."
kubectl create configmap postfix-config -n "$NS_MAIL" \
  --from-file=main.cf="$WORK_DIR/main.cf" \
  --from-file=master.cf="$MANIFESTS_DIR/postfix-master.cf" \
  --from-file=aliases="$WORK_DIR/aliases" \
  --dry-run=client -o yaml | mt_apply kubectl apply -f -

# OpenDKIM config ConfigMap
# IMPORTANT: Preserve existing KeyTable and SigningTable (managed by create_env per-tenant)
print_status "Applying opendkim-config ConfigMap..."
EXISTING_KEYTABLE=$(kubectl get configmap opendkim-config -n "$NS_MAIL" \
  -o jsonpath='{.data.KeyTable}' 2>/dev/null || echo "# Managed by create_env - tenant keys added dynamically")
EXISTING_SIGNINGTABLE=$(kubectl get configmap opendkim-config -n "$NS_MAIL" \
  -o jsonpath='{.data.SigningTable}' 2>/dev/null || echo "# Managed by create_env - tenant domains added dynamically")

kubectl create configmap opendkim-config -n "$NS_MAIL" \
  --from-file=opendkim.conf="$WORK_DIR/opendkim.conf" \
  --from-literal=KeyTable="$EXISTING_KEYTABLE" \
  --from-literal=SigningTable="$EXISTING_SIGNINGTABLE" \
  --from-file=TrustedHosts="$WORK_DIR/TrustedHosts" \
  --dry-run=client -o yaml | mt_apply kubectl apply -f -

# Init scripts ConfigMap
print_status "Applying postfix-init-scripts ConfigMap..."
kubectl create configmap postfix-init-scripts -n "$NS_MAIL" \
  --from-file=10-master-cf-overrides.sh="$MANIFESTS_DIR/10-master-cf-overrides.sh" \
  --dry-run=client -o yaml | mt_apply kubectl apply -f -

# =============================================================================
# Apply Deployment
# =============================================================================
# Use server-side apply with field manager to preserve DKIM volumes added by create_env.
# create_env patches the Deployment to add per-tenant DKIM key volumes and volume mounts.
# SSA ensures those fields (owned by kubectl-patch) are not removed when we re-apply.
print_status "Applying Postfix Deployment..."
envsubst '${NS_MAIL} ${SMTP_HOSTNAME} ${SMTP_DOMAIN} ${SMTP_ALLOWED_SENDER_DOMAINS} ${POSTFIX_MYNETWORKS} ${POSTFIX_RELAY_IP} ${HEADSCALE_URL} ${CHECKSUM_POSTFIX_CONFIG} ${CHECKSUM_OPENDKIM_CONFIG} ${CHECKSUM_INIT_SCRIPTS}' \
  < "$MANIFESTS_DIR/deployment.yaml.tpl" \
  | kubectl apply -f - --server-side --field-manager=deploy-postfix --force-conflicts

# =============================================================================
# Apply Services
# =============================================================================
print_status "Applying Postfix Services..."
envsubst '${NS_MAIL}' < "$MANIFESTS_DIR/service-smtp.yaml.tpl" | kubectl apply -f -
envsubst '${NS_MAIL}' < "$MANIFESTS_DIR/service-nodeport.yaml.tpl" | kubectl apply -f -
envsubst '${NS_MAIL}' < "$MANIFESTS_DIR/service-internal.yaml.tpl" | kubectl apply -f -

# =============================================================================
# Apply NetworkPolicy
# =============================================================================
print_status "Applying Postfix NetworkPolicy..."
envsubst '${NS_MAIL}' < "$MANIFESTS_DIR/networkpolicy.yaml.tpl" | kubectl apply -f -

# =============================================================================
# Conditional restart (only if config/secrets changed)
# =============================================================================

mt_restart_if_changed deployment/postfix -n "$NS_MAIL"

# =============================================================================
# Wait for rollout
# =============================================================================
print_status "Waiting for Postfix deployment rollout..."
kubectl rollout status deployment/postfix -n "$NS_MAIL" --timeout=120s

print_success "Postfix deployed to $NS_MAIL"
