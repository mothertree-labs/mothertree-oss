#!/bin/bash

# Deploy Postfix K8s Resources
# Purpose: Deploy Postfix SMTP server to infra-mail namespace for inbound MX dispatch.
#
# After step 2 PR-4, this pod runs a single Postfix container (no OpenDKIM sidecar,
# no submission port, no outbound SES relay). Outbound signing + relay is handled
# per-tenant by Stalwart → AWS SES Easy DKIM.
#
# Creates:
#   - ServiceAccount + RBAC (legacy — retained for rollback safety)
#   - ConfigMaps (postfix-config, postfix-init-scripts)
#   - Deployment (single Postfix container + prepare-routing init container)
#   - Service (ClusterIP port 25)
#   - Service (NodePort 30025, for inbound MX from the NodeBalancer)
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
# Compute derived variables
# =============================================================================

# Postfix uses "relay" hostname to avoid conflicts with tenant Stalwart servers
# Tenant Stalwarts use "mail.<domain>" as their hostname for user-facing SMTP
export SMTP_HOSTNAME="relay.${SMTP_DOMAIN}"

# SECURITY: Trusted relay networks for K8s Postfix
# Components:
#   - 127.0.0.0/8: localhost
#   - 10.0.0.0/8: K8s pod network (Cilium)
#   - 172.16.0.0/12: K8s service network
export POSTFIX_MYNETWORKS="127.0.0.0/8,10.0.0.0/8,172.16.0.0/12"

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
print_status "  Trusted networks: $POSTFIX_MYNETWORKS"
print_status "  Allowed sender domains: ${SMTP_ALLOWED_SENDER_DOMAINS:-<none>}"

# =============================================================================
# Process config templates
# =============================================================================

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

# Process Postfix main.cf template
# Only substitute our variables — leave Postfix $variables (e.g. $myhostname) intact
envsubst '${SMTP_HOSTNAME} ${SMTP_DOMAIN} ${POSTFIX_MYNETWORKS}' \
  < "$MANIFESTS_DIR/postfix-main.cf.tpl" > "$WORK_DIR/main.cf"

# Process aliases template
envsubst '${SMTP_DOMAIN}' \
  < "$MANIFESTS_DIR/postfix-aliases.tpl" > "$WORK_DIR/aliases"

# =============================================================================
# Compute config checksums for deployment annotations
# =============================================================================

CHECKSUM_POSTFIX_CONFIG=$(cat "$WORK_DIR/main.cf" "$MANIFESTS_DIR/postfix-master.cf" "$WORK_DIR/aliases" | shasum -a 256 | cut -d' ' -f1)
CHECKSUM_INIT_SCRIPTS=$(shasum -a 256 "$MANIFESTS_DIR/10-master-cf-overrides.sh" | cut -d' ' -f1)

export CHECKSUM_POSTFIX_CONFIG CHECKSUM_INIT_SCRIPTS

# =============================================================================
# Apply RBAC (ServiceAccount, Role, RoleBinding for Tailscale state Secrets)
# =============================================================================

print_status "Applying Postfix RBAC..."
mt_reset_change_tracker
envsubst '${NS_MAIL}' < "$MANIFESTS_DIR/postfix-rbac.yaml.tpl" | mt_apply kubectl apply -f -

# =============================================================================
# Clean up legacy Tailscale sidecar artifacts (issue #348 migration)
# =============================================================================
kubectl delete secret postfix-tailscale-auth -n "$NS_MAIL" --ignore-not-found=true >/dev/null 2>&1 || true
for legacy_secret in $(kubectl get secrets -n "$NS_MAIL" -o name 2>/dev/null | grep -E '^secret/postfix-tailscale-state-' || true); do
  kubectl delete "$legacy_secret" -n "$NS_MAIL" --ignore-not-found=true >/dev/null 2>&1 || true
done
kubectl delete role postfix-tailscale -n "$NS_MAIL" --ignore-not-found=true >/dev/null 2>&1 || true
kubectl delete rolebinding postfix-tailscale -n "$NS_MAIL" --ignore-not-found=true >/dev/null 2>&1 || true

# =============================================================================
# Clean up legacy PR-4 artifacts (SES relay + OpenDKIM sidecar)
# =============================================================================
# After step 2 PR-4, infra-Postfix no longer relays outbound (tenant Stalwarts do
# that) and no longer signs DKIM (AWS SES Easy DKIM does). Drop the Secrets and
# ConfigMaps that only those two features needed. Per-tenant dkim-key-<tenant>
# Secrets are cleaned up in the PR-4 rollout notes — they were only consumed by
# the OpenDKIM sidecar which is gone, and nothing in-cluster references them.
kubectl delete secret ses-credentials -n "$NS_MAIL" --ignore-not-found=true >/dev/null 2>&1 || true
kubectl delete configmap postfix-ses-env -n "$NS_MAIL" --ignore-not-found=true >/dev/null 2>&1 || true
kubectl delete configmap opendkim-config -n "$NS_MAIL" --ignore-not-found=true >/dev/null 2>&1 || true
for legacy_dkim in $(kubectl get secrets -n "$NS_MAIL" -o name 2>/dev/null | grep -E '^secret/dkim-key-' || true); do
  kubectl delete "$legacy_dkim" -n "$NS_MAIL" --ignore-not-found=true >/dev/null 2>&1 || true
done
# The submission-only Service is gone too.
kubectl delete service postfix-internal -n "$NS_MAIL" --ignore-not-found=true >/dev/null 2>&1 || true

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

# Init scripts ConfigMap
print_status "Applying postfix-init-scripts ConfigMap..."
kubectl create configmap postfix-init-scripts -n "$NS_MAIL" \
  --from-file=10-master-cf-overrides.sh="$MANIFESTS_DIR/10-master-cf-overrides.sh" \
  --dry-run=client -o yaml | mt_apply kubectl apply -f -

# =============================================================================
# Apply Deployment
# =============================================================================
print_status "Applying Postfix Deployment..."
envsubst '${NS_MAIL} ${SMTP_HOSTNAME} ${SMTP_DOMAIN} ${SMTP_ALLOWED_SENDER_DOMAINS} ${POSTFIX_MYNETWORKS} ${CHECKSUM_POSTFIX_CONFIG} ${CHECKSUM_INIT_SCRIPTS}' \
  < "$MANIFESTS_DIR/deployment.yaml.tpl" \
  | mt_apply kubectl apply -f -

# =============================================================================
# Apply Services
# =============================================================================
print_status "Applying Postfix Services..."
envsubst '${NS_MAIL}' < "$MANIFESTS_DIR/service-smtp.yaml.tpl" | kubectl apply -f -
envsubst '${NS_MAIL}' < "$MANIFESTS_DIR/service-nodeport.yaml.tpl" | kubectl apply -f -

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
