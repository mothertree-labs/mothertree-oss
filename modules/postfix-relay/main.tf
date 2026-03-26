terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 3.9"
    }
  }
}

# SSH Key for Postfix relay server
resource "linode_sshkey" "postfix_relay_key" {
  label   = "${var.postfix_relay_label}-ssh-key"
  ssh_key = var.ssh_public_key
}

# Firewall for Postfix relay server
# Postfix relay receives inbound MX mail on port 25 from the internet.
# All other traffic (K8s Postfix → relay, Ansible → relay) goes through the Tailscale mesh.
resource "linode_firewall" "postfix_relay_firewall" {
  label = "${var.postfix_relay_label}-firewall"
  tags  = var.tags

  # Default policies
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  # SSH access — restricted to specific admin IPs only
  dynamic "inbound" {
    for_each = length(var.admin_ssh_cidrs) > 0 ? [1] : []
    content {
      label    = "SSH"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = "22"
      ipv4     = var.admin_ssh_cidrs
    }
  }

  # SMTP inbound — MX mail from the internet
  inbound {
    label    = "SMTP"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "25"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # Tailscale/WireGuard — UDP 41641
  inbound {
    label    = "Tailscale-WireGuard"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "41641"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # Certbot HTTP-01 challenge (Let's Encrypt TLS cert for Postfix)
  inbound {
    label    = "Certbot-HTTP"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }
}

# Postfix Relay Server Instance
resource "linode_instance" "postfix_relay" {
  label  = var.postfix_relay_label
  image  = var.postfix_relay_image
  region = var.region
  type   = var.postfix_relay_type
  tags   = concat(var.tags, ["postfix", "mail-relay"])

  authorized_keys = [var.ssh_public_key]

  # Assign the firewall
  firewall_id = linode_firewall.postfix_relay_firewall.id

  # Public interface only — K8s Postfix reaches this via Tailscale mesh
  dynamic "interface" {
    for_each = [1]
    content {
      purpose = "public"
      primary = true
    }
  }

  # Cloud-init user data
  metadata {
    user_data = base64encode(templatefile("${path.module}/user-data.yaml", {
      headscale_url      = var.headscale_url
      tailscale_auth_key = var.tailscale_auth_key
    }))
  }

  depends_on = [
    linode_sshkey.postfix_relay_key,
    linode_firewall.postfix_relay_firewall
  ]

  # metadata (user_data) only runs on first boot
  lifecycle {
    ignore_changes = [disk, metadata]
  }
}
