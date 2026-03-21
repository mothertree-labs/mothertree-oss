# Infrastructure Configuration for Matrix
# This file manages only infrastructure resources (PVCs, namespaces, DNS, etc.)
# Applications are managed by Helmfile in the apps/ directory

terraform {
  required_version = ">= 1.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.17"
    }
    linode = {
      source  = "linode/linode"
      version = "~> 3.9"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# Data sources
data "terraform_remote_state" "phase1" {
  backend = "local"
  config = {
    path = "../phase1/terraform.tfstate.d/${var.env}/terraform.tfstate"
  }
}

# Get cluster IP address from the ingress controller service
data "external" "cluster_ip" {
  program    = ["bash", "-c", "KUBECONFIG=${path.root}/../kubeconfig.${var.env}.yaml kubectl get service -n infra-ingress ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | jq -R -s -c '{ip: .}'"]
  depends_on = [data.kubernetes_namespace.db]
}

# Get cluster IP address from Kubernetes service
locals {
  # Get the actual IP address from the ingress controller service
  cluster_ip_address = data.external.cluster_ip.result.ip
}

# Configure Kubernetes provider using kubeconfig
provider "kubernetes" {
  config_path = "${path.root}/../kubeconfig.${var.env}.yaml"
}

provider "kubectl" {
  config_path = "${path.root}/../kubeconfig.${var.env}.yaml"
}

# Ensure cert-manager CRDs are present before applying any cert-manager resources
# Helmfile installs cert-manager; this waits until CRDs and namespace exist
# Configure the Cloudflare Provider
provider "cloudflare" {
  api_token = var.cloudflare_api_token
  # Optional: Configure API rate limiting
  # rps = 4
}

# Configure the Linode Provider
provider "linode" {
  token = var.linode_token
}

# Local variables
locals {
  # TURN server configuration
  turn_uris = data.terraform_remote_state.phase1.outputs.turn_server_enabled ? [
    "turn:${data.terraform_remote_state.phase1.outputs.turn_server_ip}:3478?transport=udp",
    "turn:${data.terraform_remote_state.phase1.outputs.turn_server_ip}:3478?transport=tcp",
    "turn:${data.terraform_remote_state.phase1.outputs.turn_server_ip}:3479?transport=udp",
    "turn:${data.terraform_remote_state.phase1.outputs.turn_server_ip}:3479?transport=tcp"
  ] : []

}

# Reference shared database namespace (infra-db)
# Created by deploy_infra script before Terraform runs
data "kubernetes_namespace" "db" {
  metadata {
    name = "infra-db"
  }
}

# Note: Tenant namespaces (tn-<tenant>-*) are created by scripts/create_env
# This keeps Terraform focused on shared infrastructure only

# Note: ClusterIssuers and Cloudflare API token secret are now managed by
# deploy_infra script (apps/manifests/cert-manager/) instead of Terraform.

# Note: Synapse Admin is now deployed by scripts/create_env
# This keeps tenant-specific resources out of Terraform

# Note: Synapse subdomain ingress for federation (.well-known) is now deployed by scripts/create_env
# This keeps tenant-specific resources out of Terraform

// Helm manages application PVCs; do not pre-create them here to avoid ownership conflicts

# Note: VPN server readiness check and Unbound DNS configuration are now
# managed by Ansible (playbook.yml — "Configure VPN Networking" play)
# instead of Terraform null_resource provisioners.

# NOTE: Internal ingress whitelist CIDRs are now managed by Helm via deploy_infra script
# The script computes the CIDRs and passes them to helmfile as environment variables
# This avoids field manager conflicts between Helm and kubectl patch
# See: apps/environments/*/ingress-nginx-internal.yaml.gotmpl

# Use exact VPN server VPC/LAN CIDR from phase1 outputs (support subnet)
locals {
  vpn_server_vpc_cidr = data.terraform_remote_state.phase1.outputs.vpn_server_vpc_cidr
  # Compute OpenVPN server eth0 /24 subnet CIDR from its private IP
  openvpn_server_private_ip_octets = split(".", data.terraform_remote_state.phase1.outputs.openvpn_server_private_ip)
  vpn_server_eth0_subnet_cidr = format("%s.%s.%s.0/24",
    local.openvpn_server_private_ip_octets[0],
    local.openvpn_server_private_ip_octets[1],
    local.openvpn_server_private_ip_octets[2]
  )
}

# Note: CoreDNS and internal ingress are managed by Helmfile
# This keeps Terraform focused on infrastructure (DNS, instances, firewalls)
# Note: Postfix K8s resources are managed by apps/deploy-postfix.sh (not Terraform)

# =============================================================================
# DNS Management Module
# =============================================================================

module "dns_update" {
  source = "../modules/dns"

  # Pass required variables
  domain               = var.domain
  cluster_ip_address   = local.cluster_ip_address
  dns_provider         = "cloudflare"
  cloudflare_api_token = var.cloudflare_api_token
  cloudflare_zone_id   = var.cloudflare_zone_id
  matrix_cname         = var.matrix_subdomain
  synapse_cname        = var.admin_subdomain
  turn_server_ip       = data.terraform_remote_state.phase1.outputs.turn_server_ip
  vpn_server_ip        = data.terraform_remote_state.phase1.outputs.openvpn_server_ip
  tags                 = var.tags
  env_dns_label        = var.env_dns_label

  # Additional DNS module variables
  # For prod (env_dns_label == ""), use "lb1.prod" for internal infrastructure
  # User-facing URLs (matrix.example.com) will point to lb1.prod.example.com
  # For other envs, use "lb1.<env>" to get lb1.dev.example.com, etc.
  lb1_subdomain = var.env_dns_label == "" ? "lb1.prod" : "lb1.${var.env_dns_label}"

  # NOTE: mail_lb_ip removed - K8s Postfix is now internal-only
  # Inbound mail architecture needs redesign

  # NOTE: DKIM/SPF/DMARC DNS records now managed per-tenant by create_env
}

# =============================================================================
# Reverse DNS (PTR) for VPN server public IP
# =============================================================================
#
# Linode requires the rDNS hostname to resolve at the time the PTR is set.
# The `modules/dns` module creates the corresponding Cloudflare A record (mail.*):
# - prod: mail.example.com
# - dev:  mail.dev.example.com
#
# Therefore, manage rDNS here (phase2) after `module.dns_update`.
resource "linode_rdns" "mail_relay" {
  address = data.terraform_remote_state.phase1.outputs.openvpn_server_ip
  rdns    = var.env_dns_label == "" ? "mail.${var.domain}" : "mail.${var.env_dns_label}.${var.domain}"

  depends_on = [module.dns_update]
}