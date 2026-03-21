#!/bin/bash

# Manage Infrastructure DNS Records
# Purpose: Create/update Cloudflare DNS records and Linode reverse DNS
#          for shared infrastructure (not per-tenant records).
#
# Records managed:
#   - lb1.{prod|dev}.<domain> A        → Ingress LB IP (proxied in prod)
#   - turn[.dev].<domain> A            → TURN server IP
#   - mail[.dev].<domain> A            → VPN server IP
#   - vpn.{prod|dev}.<domain> A        → VPN server IP
#   - @ CNAME → www.<domain>           (prod only)
#   - mail MX → mail.<domain>          (prod only)
#   - _matrix._tcp SRV                 → synapse[.dev].<domain>:443
#   - _matrix-fed._tcp SRV             → synapse[.dev].<domain>:8448
#   - PTR (rDNS) for VPN server IP     → mail[.dev].<domain>
#
# Called by: manage_infra (after phase1 Terraform)
# Can also be run standalone.
#
# Usage:
#   ./scripts/manage-dns.sh -e <env> [--lb-ip=X.X.X.X]
#
# The lb1 A record requires the ingress LB IP. By default this is queried
# from K8s (requires the ingress controller to be deployed). Use --lb-ip
# to override, or the script will skip the lb1 record if unavailable.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/args.sh"

mt_usage() {
  echo "Usage: $0 -e <env> [--lb-ip=X.X.X.X]"
  echo ""
  echo "Create/update infrastructure DNS records (Cloudflare + Linode rDNS)."
  echo ""
  echo "Options:"
  echo "  -e <env>           Environment (e.g., dev, prod)"
  echo "  --lb-ip=X.X.X.X   Ingress LB IP (auto-detected from K8s if omitted)"
  echo "  -h, --help         Show this help"
}

mt_parse_args "$@"
mt_require_env

# Load infrastructure configuration (sets INFRA_DOMAIN, VPN_SERVER_IP, TURN_SERVER_IP, etc.)
source "${REPO_ROOT}/scripts/lib/infra-config.sh"
mt_load_infra_config

# Load Cloudflare and Linode credentials from secrets
# manage_infra sources secrets.tfvars.env; we support both shared and per-env secrets
if [ -f "$REPO_ROOT/secrets.tfvars.env" ]; then
  source "$REPO_ROOT/secrets.tfvars.env"
elif [ -f "$REPO_ROOT/secrets.${MT_ENV}.tfvars.env" ]; then
  source "$REPO_ROOT/secrets.${MT_ENV}.tfvars.env"
else
  print_error "No secrets file found. Expected $REPO_ROOT/secrets.tfvars.env"
  exit 1
fi

mt_require_commands curl jq kubectl

# Validate required credentials
if [ -z "${TF_VAR_cloudflare_api_token:-}" ]; then
  print_error "TF_VAR_cloudflare_api_token not set"
  exit 1
fi
if [ -z "${TF_VAR_cloudflare_zone_id:-}" ]; then
  print_error "TF_VAR_cloudflare_zone_id not set"
  exit 1
fi

# Load shared DNS functions
source "${REPO_ROOT}/scripts/lib/dns.sh"

# =============================================================================
# Compute DNS variables
# =============================================================================

DOMAIN="$INFRA_DOMAIN"

# Environment DNS label: "" for prod, "dev" for dev
ENV_DOT=""
if [ -n "$INFRA_ENV_DNS_LABEL" ]; then
  ENV_DOT="${INFRA_ENV_DNS_LABEL}."
fi

# Subdomain defaults (match previous Terraform defaults)
SYNAPSE_CNAME="${SYNAPSE_CNAME:-synapse}"

# LB1 subdomain: lb1.prod for prod, lb1.dev for dev
if [ -z "$INFRA_ENV_DNS_LABEL" ]; then
  LB1_SUBDOMAIN="lb1.prod"
  CF_PROXIED="true"
else
  LB1_SUBDOMAIN="lb1.${INFRA_ENV_DNS_LABEL}"
  CF_PROXIED="false"
fi

# Get ingress LB IP — from flag, K8s query, or skip
LB_IP_OVERRIDE=$(mt_get_flag_value "--lb-ip" || echo "")
if [ -n "$LB_IP_OVERRIDE" ]; then
  INGRESS_LB_IP="$LB_IP_OVERRIDE"
else
  INGRESS_LB_IP=$(kubectl get service -n "$NS_INGRESS" ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
fi

print_status "Managing infrastructure DNS records (env: $MT_ENV)"
print_status "  Domain: $DOMAIN"
print_status "  VPN server IP: $VPN_SERVER_IP"
print_status "  TURN server IP: ${TURN_SERVER_IP:-<not set>}"
print_status "  Ingress LB IP: ${INGRESS_LB_IP:-<not available>}"

# =============================================================================
# Create/update DNS records
# =============================================================================

# 1. lb1 A record — ingress load balancer
if [ -n "$INGRESS_LB_IP" ]; then
  create_dns_record "${LB1_SUBDOMAIN}.${DOMAIN}" "A" "$INGRESS_LB_IP" "$CF_PROXIED"
else
  print_warning "Skipping lb1 A record — ingress LB IP not available (run deploy_infra first, then re-run with --dns)"
fi

# 2. TURN server A record
if [ -n "${TURN_SERVER_IP:-}" ]; then
  create_dns_record "turn.${ENV_DOT}${DOMAIN}" "A" "$TURN_SERVER_IP"
else
  print_warning "Skipping TURN A record — TURN server IP not available"
fi

# 3. Mail A record — VPN server (accepts inbound mail)
if [ -n "$VPN_SERVER_IP" ]; then
  create_dns_record "mail.${ENV_DOT}${DOMAIN}" "A" "$VPN_SERVER_IP"
fi

# 4. VPN server A record
if [ -n "$VPN_SERVER_IP" ]; then
  local_vpn_label=""
  if [ -z "$INFRA_ENV_DNS_LABEL" ]; then
    local_vpn_label="vpn.prod"
  else
    local_vpn_label="vpn.${INFRA_ENV_DNS_LABEL}"
  fi
  create_dns_record "${local_vpn_label}.${DOMAIN}" "A" "$VPN_SERVER_IP"
fi

# 5. Base domain CNAME → www (prod only)
# Cloudflare handles CNAME flattening at the root domain automatically
if [ -z "$INFRA_ENV_DNS_LABEL" ]; then
  create_dns_record "${DOMAIN}" "CNAME" "www.${DOMAIN}" "true"
fi

# 6. Mail MX record (prod only)
# Points mail subdomain to the mail A record
if [ -z "$INFRA_ENV_DNS_LABEL" ]; then
  create_mx_record "mail.${DOMAIN}" "mail.${DOMAIN}" 10
fi

# 7. Matrix federation SRV records
# SRV domain must match the Matrix server_name:
#   prod: _matrix._tcp.mother-tree.org → synapse.mother-tree.org
#   dev:  _matrix._tcp.dev.mother-tree.org → synapse.dev.mother-tree.org
SYNAPSE_TARGET="${SYNAPSE_CNAME}.${ENV_DOT}${DOMAIN}"
SRV_DOMAIN="${ENV_DOT}${DOMAIN}"
create_srv_record "_matrix" "_tcp" "$SRV_DOMAIN" 10 5 443 "$SYNAPSE_TARGET"
create_srv_record "_matrix-fed" "_tcp" "$SRV_DOMAIN" 10 5 8448 "$SYNAPSE_TARGET"

# =============================================================================
# Set Linode reverse DNS (PTR) for VPN server
# =============================================================================
# rDNS must be set AFTER the mail A record exists (Linode validates forward DNS)
if [ -n "$VPN_SERVER_IP" ] && [ -n "${TF_VAR_linode_token:-}" ]; then
  MAIL_RDNS="mail.${ENV_DOT}${DOMAIN}"
  print_status "Setting reverse DNS for $VPN_SERVER_IP -> $MAIL_RDNS"
  set_linode_rdns "$VPN_SERVER_IP" "$MAIL_RDNS"
else
  print_warning "Skipping rDNS — VPN server IP or Linode token not available"
fi

print_success "Infrastructure DNS records configured for $MT_ENV"
