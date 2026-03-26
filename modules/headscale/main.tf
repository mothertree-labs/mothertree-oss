terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 3.9"
    }
  }
}

# SSH Key for Headscale server
resource "linode_sshkey" "headscale_key" {
  label   = "${var.headscale_label}-ssh-key"
  ssh_key = var.ssh_public_key
}

# Firewall for Headscale server
resource "linode_firewall" "headscale_firewall" {
  label = "${var.headscale_label}-firewall"
  tags  = var.tags

  # Default policies
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  # SSH access - restricted to specific admin IPs only
  # When admin_ssh_cidrs is empty, no SSH rule is created (SSH blocked by DROP policy)
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

  # DERP relay - TCP 443
  # Used by Tailscale clients for NAT traversal when direct WireGuard fails
  inbound {
    label    = "DERP-Relay"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "443"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # STUN - UDP 3478
  # Used for NAT type detection and hole-punching
  inbound {
    label    = "STUN"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "3478"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # Headscale API / coordination - TCP 8080
  # Tailscale clients connect here for key exchange and peer discovery.
  # Must be open to all nodes that will join the tailnet.
  inbound {
    label    = "Headscale-API"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "8080"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # Certbot HTTP-01: Let's Encrypt must reach this host on port 80
  # for initial DERP TLS certificate provisioning.
  # UFW on the server only allows 80 during certbot runs.
  inbound {
    label    = "Certbot-HTTP-01"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }
}

# Persistent volume for Headscale state (SQLite DB, noise private key)
resource "linode_volume" "headscale_data" {
  label  = "${var.headscale_label}-data"
  region = var.region
  size   = 10 # 10GB minimum
  tags   = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

# Headscale Server Instance
resource "linode_instance" "headscale_server" {
  label  = var.headscale_label
  image  = var.headscale_image
  region = var.region
  type   = var.headscale_type
  tags   = concat(var.tags, ["headscale", "tailnet"])

  authorized_keys = [var.ssh_public_key]

  # Assign the firewall
  firewall_id = linode_firewall.headscale_firewall.id

  # Public interface only — Headscale needs a stable public IP for DERP/STUN
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
      headscale_version = var.headscale_version
      domain            = var.domain
      base_domain       = var.base_domain
    }))
  }

  depends_on = [
    linode_sshkey.headscale_key,
    linode_firewall.headscale_firewall
  ]

  # metadata (user_data) only runs on first boot — changes to computed values
  # in the template shouldn't trigger recreation. If user_data needs updating,
  # manually taint the resource.
  lifecycle {
    ignore_changes = [disk, metadata]
  }
}

# Attach volume to the instance after it's created
resource "null_resource" "attach_volume" {
  depends_on = [linode_instance.headscale_server]

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for instance to be ready
      sleep 30

      # Attach volume to instance
      curl -H "Authorization: Bearer $TF_VAR_linode_token" \
           -H "Content-Type: application/json" \
           -X POST \
           "https://api.linode.com/v4/volumes/${linode_volume.headscale_data.id}/attach" \
           -d "{\"linode_id\": ${linode_instance.headscale_server.id}, \"config_id\": null}"
    EOT
  }

  triggers = {
    volume_id   = linode_volume.headscale_data.id
    instance_id = linode_instance.headscale_server.id
  }
}
