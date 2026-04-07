terraform {
  required_version = ">= 1.0"
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 3.9"
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
# SSH via Tailscale mesh only (no public SSH). Woodpecker UI via Cloudflare Tunnel (outbound only).
resource "linode_firewall" "ci_firewall" {
  label = "${var.ci_label}-firewall"
  tags  = var.tags

  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  # Allow inbound WireGuard for direct Tailscale peer connections (avoids DERP relay)
  inbound {
    label    = "Tailscale-WireGuard"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "41641"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }
}

# CI Server Instance
resource "linode_instance" "ci_server" {
  label  = var.ci_label
  image  = "linode/ubuntu24.04"
  region = var.region
  type   = var.ci_instance_type
  tags   = concat(var.tags, ["ci", "woodpecker"])

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

  # Cloud-init: install Docker and create woodpecker user
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
