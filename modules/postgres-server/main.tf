terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 3.9"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# SSH Key for PostgreSQL server
resource "linode_sshkey" "postgres_key" {
  label   = "${var.postgres_label}-ssh-key"
  ssh_key = var.ssh_public_key
}

# Firewall for PostgreSQL server
# PostgreSQL (5432) is NOT exposed — only reachable via the Tailscale interface.
# pg_hba.conf restricts connections to the Tailscale CGNAT range (100.64.0.0/10).
resource "linode_firewall" "postgres_firewall" {
  label = "${var.postgres_label}-firewall"
  tags  = var.tags

  # Default policies
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  # SSH access — restricted to specific admin IPs only
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

  # Tailscale/WireGuard — UDP 41641
  # Tailscale handles its own authentication; the port must be reachable from
  # any IP so that DERP relay and direct connections both work.
  inbound {
    label    = "Tailscale-WireGuard"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "41641"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }
}

# Persistent volume for PostgreSQL data directory
resource "linode_volume" "postgres_data" {
  label  = "${var.postgres_label}-data"
  region = var.region
  size   = var.volume_size
  tags   = var.tags
}

# PostgreSQL Server Instance
resource "linode_instance" "postgres_server" {
  label  = var.postgres_label
  image  = var.postgres_image
  region = var.region
  type   = var.postgres_type
  tags   = concat(var.tags, ["postgres", "database"])

  authorized_keys = [var.ssh_public_key]

  # Assign the firewall
  firewall_id = linode_firewall.postgres_firewall.id

  # Public interface only — all database traffic goes through the Tailscale mesh
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
      postgres_version   = var.postgres_version
      headscale_url      = var.headscale_url
      tailscale_auth_key = var.tailscale_auth_key
    }))
  }

  depends_on = [
    linode_sshkey.postgres_key,
    linode_firewall.postgres_firewall
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
  depends_on = [linode_instance.postgres_server]

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for instance to be ready
      sleep 30

      # Attach volume to instance
      curl -H "Authorization: Bearer $TF_VAR_linode_token" \
           -H "Content-Type: application/json" \
           -X POST \
           "https://api.linode.com/v4/volumes/${linode_volume.postgres_data.id}/attach" \
           -d "{\"linode_id\": ${linode_instance.postgres_server.id}, \"config_id\": null}"
    EOT
  }

  triggers = {
    volume_id   = linode_volume.postgres_data.id
    instance_id = linode_instance.postgres_server.id
  }
}
