terraform {
  required_version = ">= 1.0"
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
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

# Query Kubernetes service CIDR from the cluster
# This is needed to push the correct route in OpenVPN
data "external" "service_cidr" {
  program = ["bash", "-c", <<-EOT
    set -e
    # Wait for cluster to be ready and have at least one service
    max_attempts=30
    attempt=0
    while [ $attempt -lt $max_attempts ]; do
      # Try to get kube-dns service (always exists)
      CIDR=$(KUBECONFIG=${path.root}/../kubeconfig.${var.env}.yaml kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
      if [ -n "$CIDR" ] && [ "$CIDR" != "" ]; then
        # Extract CIDR from ClusterIP (assume /16 for service CIDR)
        # Convert to netmask format for OpenVPN: 10.128.0.0 255.255.0.0
        IP=$(echo "$CIDR" | cut -d. -f1-2)
        echo "{\"route\": \"$IP.0.0 255.255.0.0\"}"
        exit 0
      fi
      attempt=$((attempt + 1))
      if [ $attempt -lt $max_attempts ]; then
        sleep 2
      fi
    done
    # Fail if service CIDR cannot be determined
    echo "Error: Could not determine service CIDR from cluster after $((max_attempts * 2)) seconds" >&2
    echo "Make sure the cluster is fully provisioned and kube-dns service exists" >&2
    exit 1
  EOT
  ]
  depends_on = [local_file.kubeconfig]
}

# Query cluster node IP and subnet dynamically from actual node IPs
# This determines the actual subnet where cluster nodes are located (e.g., 192.168.156.x)
# Also computes the Linode private network range (/17) for firewall rules
data "external" "cluster_node_subnet" {
  program = ["bash", "-c", <<-EOT
    set -e
    # Wait for cluster to have nodes
    max_attempts=30
    attempt=0
    while [ $attempt -lt $max_attempts ]; do
      # Get first node internal IP
      NODE_IP=$(KUBECONFIG=${path.root}/../kubeconfig.${var.env}.yaml kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
      if [ -n "$NODE_IP" ] && [ "$NODE_IP" != "" ]; then
        # Extract subnet from node IP (assume /24 for subnet)
        # Convert to netmask format for OpenVPN: 192.168.156.0 255.255.255.0
        SUBNET=$(echo "$NODE_IP" | cut -d. -f1-3)
        # Also compute the Linode private network CIDR
        # Linode uses 192.168.128.0/17 for legacy private networking
        # We detect this by checking if second octet is 168 and third >= 128
        OCTET2=$(echo "$NODE_IP" | cut -d. -f2)
        OCTET3=$(echo "$NODE_IP" | cut -d. -f3)
        if [ "$OCTET2" = "168" ] && [ "$OCTET3" -ge 128 ]; then
          # Legacy Linode private network
          PRIVATE_CIDR="192.168.128.0/17"
        else
          # Assume it's a /16 based on first two octets
          OCTET1=$(echo "$NODE_IP" | cut -d. -f1)
          PRIVATE_CIDR="$OCTET1.$OCTET2.0.0/16"
        fi
        echo "{\"route\": \"$SUBNET.0 255.255.255.0\", \"ip\": \"$NODE_IP\", \"cidr\": \"$SUBNET.0/24\", \"private_network_cidr\": \"$PRIVATE_CIDR\"}"
        exit 0
      fi
      attempt=$((attempt + 1))
      if [ $attempt -lt $max_attempts ]; then
        sleep 2
      fi
    done
    # Fail if node subnet cannot be determined
    echo "Error: Could not determine cluster node subnet from nodes after $((max_attempts * 2)) seconds" >&2
    echo "Make sure the cluster has nodes and they have InternalIP addresses" >&2
    exit 1
  EOT
  ]
  depends_on = [local_file.kubeconfig]
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

  # SSH access - restricted to admin IPs and VPN server (as SSH bastion).
  # deploy_infra uses ProxyJump through the VPN server to reach the TURN server,
  # so the TURN server sees SSH from the VPN server's public IP.
  inbound {
    label    = "SSH"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = distinct(concat(var.admin_ssh_cidrs, ["${module.openvpn_server.openvpn_server_ip}/32"]))
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

# Create VPC subnet for VPN/supporting services
resource "linode_vpc_subnet" "support_subnet" {
  vpc_id = module.lke_cluster.vpc_id
  label  = "${var.cluster_label}-support-subnet"
  ipv4   = "192.168.1.0/24" # 192.168.1.1 - 192.168.1.254 (254 IPs)
}

# OpenVPN Server Module
module "openvpn_server" {
  source = "../modules/openvpn-server"

  openvpn_label    = "${var.openvpn_label}-${var.env}"
  openvpn_type     = var.openvpn_type
  openvpn_image    = var.openvpn_image
  region           = var.linode_region
  ssh_public_key   = var.ssh_public_key
  vpn_network_cidr = var.vpn_network_cidr
  cluster_ip       = module.lke_cluster.cluster_ip_address
  dns_server_ip    = "10.8.0.1" # VPN server's VPN interface IP for Unbound DNS
  domain           = "${var.env_dns_label != "" ? "${var.env_dns_label}" : "prod"}.${var.domain}"
  disk_size        = var.openvpn_disk_size
  tags             = sort(concat(var.common_tags, [var.env]))
  env              = var.env
  service_cidr     = data.external.service_cidr.result.route
  # Convert cluster subnet CIDR to netmask format for OpenVPN (192.168.64.0/18 -> 192.168.64.0 255.255.192.0)
  cluster_subnet_cidr = replace(module.lke_cluster.vpc_subnet_range, "/18", " 255.255.192.0")
  # Get actual cluster node subnet from live node IPs (dynamically determined)
  vpn_server_subnet_cidr = data.external.cluster_node_subnet.result.route
  cluster_node_ip        = data.external.cluster_node_subnet.result.ip
  # Cluster node network CIDR for firewall rules (dynamically computed from actual node IPs)
  cluster_node_cidr = data.external.cluster_node_subnet.result.private_network_cidr

  # Add VPC configuration
  vpc_id        = module.lke_cluster.vpc_id
  vpc_subnet_id = linode_vpc_subnet.support_subnet.id

  # SSH access restriction
  admin_ssh_cidrs = var.admin_ssh_cidrs

  depends_on = [module.lke_cluster, local_file.kubeconfig, data.external.service_cidr, data.external.cluster_node_subnet]
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

  # SSH access only - VNC accessed via SSH port forwarding
  inbound {
    label    = "SSH"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
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


