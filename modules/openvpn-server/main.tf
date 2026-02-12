terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
  }
}

# SSH Key for OpenVPN server
resource "linode_sshkey" "openvpn_key" {
  label   = "${var.openvpn_label}-ssh-key"
  ssh_key = var.ssh_public_key
}

# Firewall for OpenVPN server
resource "linode_firewall" "openvpn_firewall" {
  label = "${var.openvpn_label}-firewall"
  tags  = var.tags

  # Default policies
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  # SSH access - restricted to specific admin IPs only
  # This IS the VPN server, so VPN network CIDR is not added here
  # Public SSH is not needed; connect via VPN first, then SSH
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

  # OpenVPN access
  inbound {
    label    = "OpenVPN"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "1194"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # Allow VPN clients to access Kubernetes cluster
  inbound {
    label    = "K8s-API"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "6443"
    ipv4     = [var.vpn_network_cidr]
  }

  # Allow VPN clients to access internal services
  inbound {
    label    = "Internal-Services"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80,443,30053,30054"
    ipv4     = [var.vpn_network_cidr]
  }

  # SMTP relay - accept from K8s cluster nodes and VPN clients
  # Used for outbound email relay with fixed source IP
  inbound {
    label    = "SMTP-Relay"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "25"
    ipv4     = [var.cluster_node_cidr, var.vpn_network_cidr]
  }

  # SMTP inbound - accept from internet for incoming mail
  # VPN Postfix uses relay_domains to only accept mail for our domains
  # (not an open relay - external senders can only deliver TO our domains)
  inbound {
    label    = "SMTP-Inbound"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "25"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # Certbot HTTP-01: Let's Encrypt must reach this host on port 80.
  # UFW on the server only allows 80 during certbot (renewal hooks).
  inbound {
    label    = "Certbot-HTTP-01"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }
}

# Persistent volume for PKI certificates
resource "linode_volume" "openvpn_pki" {
  label  = "${var.openvpn_label}-pki"
  region = var.region
  size   = 10 # 10GB minimum
  tags   = var.tags
}

# OpenVPN Server Instance
resource "linode_instance" "openvpn_server" {
  label  = var.openvpn_label
  image  = var.openvpn_image
  region = var.region
  type   = var.openvpn_type
  tags   = concat(var.tags, ["openvpn", "vpn"])

  authorized_keys = [var.ssh_public_key]

  # Assign the firewall
  firewall_id = linode_firewall.openvpn_firewall.id

  # Basic server setup
  private_ip = true

  # IMPORTANT: Public interface MUST come first to be the primary interface
  # Otherwise the VPC interface becomes primary and breaks internet connectivity
  dynamic "interface" {
    for_each = [1]
    content {
      purpose = "public"
      primary = true
    }
  }

  # Attach to VPC if provided - enables private networking to K8s cluster
  # This MUST come after the public interface
  dynamic "interface" {
    for_each = var.vpc_id != null ? [1] : []
    content {
      purpose   = "vpc"
      subnet_id = var.vpc_subnet_id
      ipv4 {
        vpc = "192.168.1.2" # Static IP in VPC for VPN server
      }
    }
  }

  # Cloud-init user data - Using full working configuration
  metadata {
    user_data = base64encode(templatefile("${path.module}/user-data.yaml", {
      vpn_network_cidr       = var.vpn_network_cidr
      cluster_ip             = var.cluster_ip
      dns_server_ip          = var.dns_server_ip
      domain                 = var.domain
      server_ip              = "self" # Will be replaced with actual IP after creation
      pki_volume_id          = linode_volume.openvpn_pki.id
      service_cidr           = var.service_cidr
      cluster_subnet_cidr    = var.cluster_subnet_cidr
      vpn_server_subnet_cidr = var.vpn_server_subnet_cidr
      cluster_node_ip        = var.cluster_node_ip
    }))
  }

  depends_on = [
    linode_sshkey.openvpn_key,
    linode_firewall.openvpn_firewall
  ]

  # Add lifecycle to prevent recreation on volume changes and metadata changes
  # metadata (user_data) only runs on first boot, so changes to computed values
  # in the template shouldn't trigger recreation. If user_data needs updating,
  # manually taint the resource.
  lifecycle {
    ignore_changes = [disk, metadata]
  }
}
# Attach volume to the instance after it's created
resource "null_resource" "attach_volume" {
  depends_on = [linode_instance.openvpn_server]

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for instance to be ready
      sleep 30
      
      # Attach volume to instance
      curl -H "Authorization: Bearer $TF_VAR_linode_token" \
           -H "Content-Type: application/json" \
           -X POST \
           "https://api.linode.com/v4/volumes/${linode_volume.openvpn_pki.id}/attach" \
           -d "{\"linode_id\": ${linode_instance.openvpn_server.id}, \"config_id\": null}"
    EOT
  }

  triggers = {
    volume_id   = linode_volume.openvpn_pki.id
    instance_id = linode_instance.openvpn_server.id
  }
}



# Note: OpenVPN setup is handled via cloud-init user_data

# Generate OpenVPN server configuration
resource "local_file" "openvpn_server_config" {
  content = templatefile("${path.module}/server.conf.tpl", {
    vpn_network_cidr       = var.vpn_network_cidr
    server_ip              = linode_instance.openvpn_server.ip_address
    dns_server_ip          = var.dns_server_ip
    domain                 = var.domain
    service_cidr           = var.service_cidr
    cluster_subnet_cidr    = var.cluster_subnet_cidr
    vpn_server_subnet_cidr = var.vpn_server_subnet_cidr
  })

  filename = "${path.root}/openvpn-server.${var.env}.conf"
}

# Generate client configuration template
resource "local_file" "openvpn_client_template" {
  content = templatefile("${path.module}/client.conf.tpl", {
    server_ip     = linode_instance.openvpn_server.ip_address
    dns_server_ip = var.dns_server_ip
    domain        = var.domain
  })

  filename = "${path.root}/openvpn-client-template.${var.env}.conf"
}

#
# NOTE: Reverse DNS for the mail relay is managed in phase2 (infra/) so that:
# - the Cloudflare A record exists before Linode validates the hostname
# - `./scripts/manage_infra` (phase1 only) stays focused on cluster/VPN creation
