terraform {
  required_version = ">= 1.0"
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 3.9"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# Configure the Linode Provider
provider "linode" {
  token = var.linode_token
}

# Configure the Cloudflare Provider
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Kubernetes resources are managed in infra/ to avoid kubeconfig timing issues

# Create LKE Cluster
module "lke_cluster" {
  source = "../modules/lke-cluster"

  cluster_label    = "${var.cluster_label}-${var.env}"
  region           = var.linode_region
  k8s_version      = var.linode_k8s_version
  node_pools       = var.linode_node_pools
  tags             = sort(concat(var.common_tags, [var.env]))
  control_plane_ha = var.linode_control_plane_ha
}

# Save kubeconfig to project root directory
resource "local_file" "kubeconfig" {
  content  = base64decode(module.lke_cluster.kubeconfig)
  filename = "${path.root}/../kubeconfig.${var.env}.yaml"

  depends_on = [module.lke_cluster]
}

# Configure Kubernetes provider to query service CIDR
provider "kubernetes" {
  config_path = "${path.root}/../kubeconfig.${var.env}.yaml"
}

# ClusterIssuer moved to infra/

# Namespaces moved to infra/

# SSH Key for TURN server
resource "linode_sshkey" "turn_server_key" {
  count = var.turn_server_enabled ? 1 : 0

  label   = "${var.turn_server_label}-${var.env}-ssh-key"
  ssh_key = var.ssh_public_key
}

# Firewall for TURN server
resource "linode_firewall" "turn_server_firewall" {
  count = var.turn_server_enabled ? 1 : 0

  label = "${var.turn_server_label}-${var.env}-firewall"
  tags  = sort(concat(var.common_tags, [var.env]))

  # Default policies
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  # SSH access - restricted to admin IPs
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

  # TURN control ports
  inbound {
    label    = "TURN-3478-UDP"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "3478"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "TURN-3478-TCP"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "3478"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "TURN-3479-UDP"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "3479"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "TURN-3479-TCP"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "3479"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # TURN media relay port range
  inbound {
    label    = "TURN-media-relay"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "49152-65535"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }


}

# TURN Server Instance
resource "linode_instance" "turn_server" {
  count = var.turn_server_enabled ? 1 : 0

  label  = "${var.turn_server_label}-${var.env}"
  image  = var.turn_server_image
  region = var.linode_region
  type   = var.turn_server_type
  tags   = sort(concat(var.common_tags, [var.env, "turn", "coturn"]))

  authorized_keys = [var.ssh_public_key]

  # Assign the firewall
  firewall_id = linode_firewall.turn_server_firewall[0].id

  # Basic server setup
  private_ip = true

  depends_on = [
    linode_sshkey.turn_server_key,
    linode_firewall.turn_server_firewall
  ]
}


# SSH Key for Jitsi tester
resource "linode_sshkey" "jitsi_tester_key" {
  count = var.jitsi_tester_enabled ? 1 : 0

  label   = "${var.jitsi_tester_label}-${var.env}-ssh-key"
  ssh_key = var.ssh_public_key
}

# Firewall for Jitsi tester
resource "linode_firewall" "jitsi_tester_firewall" {
  count = var.jitsi_tester_enabled ? 1 : 0

  label = "${var.jitsi_tester_label}-${var.env}-firewall"
  tags  = sort(concat(var.common_tags, [var.env, "jitsi-tester"]))

  # Default policies
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  # SSH access - restricted to admin IPs (access via Tailscale mesh).
  # VNC is accessed via SSH port forwarding, so only SSH is needed.
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
}

# Jitsi Tester Instance
resource "linode_instance" "jitsi_tester" {
  count = var.jitsi_tester_enabled ? 1 : 0

  label  = "${var.jitsi_tester_label}-${var.env}"
  image  = "linode/ubuntu22.04"
  region = var.jitsi_tester_region
  type   = var.jitsi_tester_type
  tags   = sort(concat(var.common_tags, [var.env, "jitsi-tester", "gui"]))

  authorized_keys = [var.ssh_public_key]

  # Assign the firewall
  firewall_id = linode_firewall.jitsi_tester_firewall[0].id

  # Cloud-init user data to install Ubuntu Desktop and VNC server
  # Note: metadata block must come before any interface configuration
  metadata {
    user_data = base64encode(templatefile("${path.module}/templates/jitsi-tester-user-data.yaml", {}))
  }

  # No VPC attachment - standalone instance outside network
  # Only public interface (default, but explicitly set for clarity)
  dynamic "interface" {
    for_each = [1]
    content {
      purpose = "public"
    }
  }

  depends_on = [
    linode_sshkey.jitsi_tester_key,
    linode_firewall.jitsi_tester_firewall
  ]
}

# Headscale Server Module (self-hosted Tailscale control plane)
module "headscale_server" {
  source = "../modules/headscale"
  count  = var.headscale_enabled ? 1 : 0

  headscale_label   = "${var.headscale_label}-${var.env}"
  headscale_type    = var.headscale_type
  headscale_image   = var.headscale_image
  headscale_version = var.headscale_version
  region            = var.linode_region
  ssh_public_key    = var.ssh_public_key
  domain            = var.headscale_domain
  base_domain       = var.headscale_base_domain
  env               = var.env
  admin_ssh_cidrs   = var.admin_ssh_cidrs
  tags              = sort(concat(var.common_tags, [var.env]))
}

# PostgreSQL Server Module (dedicated database VM on Tailscale mesh)
module "postgres_server" {
  source = "../modules/postgres-server"
  count  = var.postgres_enabled ? 1 : 0

  postgres_label     = "${var.postgres_label}-${var.env}"
  postgres_type      = var.postgres_type
  postgres_image     = var.postgres_image
  postgres_version   = var.postgres_version
  region             = var.linode_region
  ssh_public_key     = var.ssh_public_key
  volume_size        = var.postgres_volume_size
  headscale_url      = var.headscale_url
  tailscale_auth_key = var.tailscale_auth_key
  env                = var.env
  admin_ssh_cidrs    = var.admin_ssh_cidrs
  tags               = sort(concat(var.common_tags, [var.env]))
}

# Postfix Relay Server Module (SMTP relay on Tailscale mesh)
module "postfix_relay" {
  source = "../modules/postfix-relay"
  count  = var.postfix_relay_enabled ? 1 : 0

  postfix_relay_label = "${var.postfix_relay_label}-${var.env}"
  postfix_relay_type  = var.postfix_relay_type
  postfix_relay_image = var.postfix_relay_image
  region              = var.linode_region
  ssh_public_key      = var.ssh_public_key
  headscale_url       = var.headscale_url
  tailscale_auth_key  = var.tailscale_auth_key
  env                 = var.env
  admin_ssh_cidrs     = var.admin_ssh_cidrs
  tags                = sort(concat(var.common_tags, [var.env]))
}
