terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

# Configure DNS provider based on the selected provider
locals {
  use_cloudflare = var.dns_provider == "cloudflare"
  envdot         = var.env_dns_label == "" ? "" : "${var.env_dns_label}."
  docs_domain    = var.docs_domain != null ? var.docs_domain : var.domain
  auth_domain    = var.auth_domain != null ? var.auth_domain : var.domain
  home_domain    = var.home_domain != null ? var.home_domain : var.domain
  matrix_domain  = var.matrix_domain != null ? var.matrix_domain : var.domain
}

# Cloudflare A record for lb1.prod.example.com
# Proxied through Cloudflare for DDoS/WAF protection (prod only)
# Dev uses DNS-only because Cloudflare Universal SSL doesn't cover *.dev.domain
resource "cloudflare_record" "lb1_a" {
  count           = local.use_cloudflare ? 1 : 0
  zone_id         = var.cloudflare_zone_id
  name            = var.lb1_subdomain
  content         = var.cluster_ip_address
  type            = "A"
  proxied         = var.env_dns_label == "" ? true : false
  ttl             = var.env_dns_label == "" ? 1 : 300
  allow_overwrite = true
}

# NOTE: Tenant subdomains (synapse, matrix, admin, docs, files, auth, home, jitsi, mail, webmail)
# are now managed by create_env script, not Terraform. This avoids conflicts and allows
# each tenant to have their own DNS records pointing to their own lb1.<env>.<domain>.

# Cloudflare A record for turn.example.com (external TURN server)
resource "cloudflare_record" "turn_a" {
  count           = local.use_cloudflare && var.turn_server_ip != null ? 1 : 0
  zone_id         = var.cloudflare_zone_id
  name            = var.env_dns_label == "" ? "turn" : "turn.${var.env_dns_label}"
  content         = var.turn_server_ip
  type            = "A"
  ttl             = 300
  allow_overwrite = true
}

# Cloudflare CNAME for example.com → www.example.com
# The www subdomain points to a separate website managed outside this infrastructure
# Cloudflare handles CNAME flattening at the root domain automatically
# Proxied through Cloudflare to protect origin IP
resource "cloudflare_record" "base_domain_cname" {
  count           = local.use_cloudflare && var.env_dns_label == "" ? 1 : 0
  zone_id         = var.cloudflare_zone_id
  name            = "@"
  content         = "www.${var.domain}"
  type            = "CNAME"
  proxied         = true
  ttl             = 1 # Required when proxied = true
  allow_overwrite = true
}

# Email DNS Records
# MX record for mail.example.com subdomain
resource "cloudflare_record" "mail_mx" {
  count           = local.use_cloudflare && var.env_dns_label == "" ? 1 : 0
  zone_id         = var.cloudflare_zone_id
  name            = "mail"
  type            = "MX"
  ttl             = 300
  allow_overwrite = true
  priority        = 10
  content         = "mail.${var.domain}"

}

# A record for mail server (mail.example.com for prod, mail.dev.example.com for dev)
# Points to the VPN server which runs Postfix relay to accept inbound mail
# VPN Postfix then relays to K8s Postfix via VPC for DKIM verification and delivery to Stalwart
resource "cloudflare_record" "mail_a" {
  count           = local.use_cloudflare && var.vpn_server_ip != null ? 1 : 0
  zone_id         = var.cloudflare_zone_id
  name            = var.env_dns_label == "" ? "mail" : "mail.${var.env_dns_label}"
  content         = var.vpn_server_ip
  type            = "A"
  ttl             = 300
  allow_overwrite = true
}

# NOTE: SPF, DKIM, and DMARC records are now managed per-tenant by create_env script
# This enables multi-tenant email configuration where each tenant has their own DKIM key
# See scripts/create_env for email DNS record creation

# Matrix Federation SRV Records
# SRV record for Matrix client-server federation
resource "cloudflare_record" "matrix_srv" {
  count           = local.use_cloudflare ? 1 : 0
  zone_id         = var.cloudflare_zone_id
  name            = "_matrix._tcp"
  type            = "SRV"
  ttl             = 300
  allow_overwrite = true

  data {
    priority = 10
    weight   = 5
    port     = 443
    target   = "${var.env_dns_label == "" ? var.synapse_cname : "${var.synapse_cname}.${var.env_dns_label}"}.${var.domain}"
  }
}

# SRV record for Matrix server-server federation (optional but recommended)
resource "cloudflare_record" "matrix_fed_srv" {
  count           = local.use_cloudflare ? 1 : 0
  zone_id         = var.cloudflare_zone_id
  name            = "_matrix-fed._tcp"
  type            = "SRV"
  ttl             = 300
  allow_overwrite = true

  data {
    priority = 10
    weight   = 5
    port     = 8448
    target   = "${var.env_dns_label == "" ? var.synapse_cname : "${var.synapse_cname}.${var.env_dns_label}"}.${var.domain}"
  }
}

# Internal DNS Records for VPN-only services
# NOTE: These public DNS records are REMOVED for security
# Internal services are served ONLY by CoreDNS to VPN clients
# No public DNS records should exist for internal services

# VPN server record
resource "cloudflare_record" "vpn_server" {
  count           = local.use_cloudflare ? 1 : 0
  zone_id         = var.cloudflare_zone_id
  name            = var.env_dns_label == "" ? "vpn.prod" : "vpn.${var.env_dns_label}"
  content         = var.vpn_server_ip
  type            = "A"
  ttl             = 300
  allow_overwrite = true
}

# MX mail host is mail.* (see cloudflare_record.mail_a above) - no separate mail-relay record 