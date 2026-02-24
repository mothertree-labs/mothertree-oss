terraform {
  required_version = ">= 1.0"
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
  }
}

provider "linode" {
  token = var.linode_token
}

# SSH Key for CI server
resource "linode_sshkey" "ci_key" {
  label   = "${var.ci_label}-ssh-key"
  ssh_key = var.ssh_public_key
}

# Firewall for CI server
# Buildkite agents connect outbound only - no inbound ports needed except SSH from VPN server
resource "linode_firewall" "ci_firewall" {
  label = "${var.ci_label}-firewall"
  tags  = var.tags

  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  # SSH access from VPN server (public IP, since Linode Cloud Firewalls filter VPC traffic
  # and don't reliably match VPC source IPs) and optional admin CIDRs (for debugging)
  inbound {
    label    = "SSH"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = distinct(concat(["${var.vpn_server_public_ip}/32"], var.admin_ssh_cidrs))
  }
}

# CI Server Instance
resource "linode_instance" "ci_server" {
  label  = var.ci_label
  image  = "linode/ubuntu24.04"
  region = var.region
  type   = var.ci_instance_type
  tags   = concat(var.tags, ["ci", "buildkite"])

  authorized_keys = [var.ssh_public_key]

  firewall_id = linode_firewall.ci_firewall.id

  private_ip = true

  # Public interface MUST come first to be the primary interface
  # Otherwise the VPC interface becomes primary and breaks internet connectivity
  dynamic "interface" {
    for_each = [1]
    content {
      purpose = "public"
      primary = true
    }
  }

  # VPC interface on support subnet (same subnet as VPN server at 192.168.1.2)
  dynamic "interface" {
    for_each = [1]
    content {
      purpose   = "vpc"
      subnet_id = var.vpc_subnet_id
      ipv4 {
        vpc = var.ci_vpc_ip
      }
    }
  }

  # Cloud-init: install Docker and create buildkite user
  metadata {
    user_data = base64encode(templatefile("${path.module}/user-data.yaml", {}))
  }

  depends_on = [
    linode_sshkey.ci_key,
    linode_firewall.ci_firewall
  ]

  lifecycle {
    ignore_changes = [disk, metadata]
  }
}
