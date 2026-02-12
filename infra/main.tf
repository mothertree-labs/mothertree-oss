# Infrastructure Configuration for Matrix
# This file manages only infrastructure resources (PVCs, namespaces, DNS, etc.)
# Applications are managed by Helmfile in the apps/ directory

terraform {
  required_version = ">= 1.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
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

# Get Kubernetes node external IPs for SPF record (emails egress through node IPs)
data "external" "node_external_ips" {
  program = ["bash", "-c", <<-EOF
    KUBECONFIG=${path.root}/../kubeconfig.${var.env}.yaml kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="ExternalIP")].address}' | tr ' ' '\n' | sort -u | jq -R -s -c 'split("\n") | map(select(length > 0)) | {ips: join(",")}'
  EOF
  ]
  depends_on = [data.kubernetes_namespace.db]
}

# Get cluster IP address from Kubernetes service
locals {
  # Get the actual IP address from the ingress controller service
  cluster_ip_address = data.external.cluster_ip.result.ip
  # Get node external IPs for SPF record
  node_external_ips = compact(split(",", data.external.node_external_ips.result.ips))
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
resource "null_resource" "wait_for_cert_manager" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${path.root}/../kubeconfig.${var.env}.yaml
      echo "Waiting for cert-manager CRDs and namespace to be available..."
      max_attempts=60
      attempt=0
      until kubectl get namespace infra-cert-manager >/dev/null 2>&1 \
        && kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1 \
        && kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ $attempt -ge $max_attempts ]; then
          echo "Timeout waiting for cert-manager CRDs/namespace" >&2
          exit 1
        fi
        echo "Attempt $attempt/$max_attempts: cert-manager not ready yet, retrying in 5s..."
        sleep 5
      done
      echo "cert-manager CRDs and namespace are available."
    EOT
  }
}

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

# =============================================================================
# Cloudflare IP ranges (read from reference files — single source of truth)
# Used by linode_firewall to restrict HTTP/S to Cloudflare + VPN
# =============================================================================
locals {
  cloudflare_ipv4 = [for line in split("\n", trimspace(file("${path.module}/../scripts/cloudflare-ips-v4.txt"))) : line if line != "" && !startswith(line, "#")]
  cloudflare_ipv6 = [for line in split("\n", trimspace(file("${path.module}/../scripts/cloudflare-ips-v6.txt"))) : line if line != "" && !startswith(line, "#")]
}

# =============================================================================
# Cloud Firewall for NodeBalancer
# Restricts HTTP/S to Cloudflare + VPN IPs; allows all other TCP (mail ports)
# =============================================================================
resource "linode_firewall" "nodebalancer" {
  label = "mothertree-${var.env_dns_label != "" ? var.env_dns_label : "prod"}-nb"

  # Rule 1: Allow HTTP/S from Cloudflare proxy IPs
  inbound {
    label    = "cloudflare-https"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80,443"
    ipv4     = local.cloudflare_ipv4
    ipv6     = local.cloudflare_ipv6
  }

  # Rule 2: Allow HTTP/S from VPN server (for internal/debug access)
  # VPN clients are NAT'd through the VPN server's public IP
  inbound {
    label    = "vpn-https"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80,443"
    ipv4     = ["${data.terraform_remote_state.phase1.outputs.openvpn_server_ip}/32"]
  }

  # Rule 3: Drop HTTP/S from all other sources
  inbound {
    label    = "drop-direct-https"
    action   = "DROP"
    protocol = "TCP"
    ports    = "80,443"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # Rule 4: Allow all other TCP (mail ports 465xx, 587xx, 993x, etc.)
  # Excludes 80 and 443 which are handled by rules above
  inbound {
    label    = "allow-other-tcp"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "1-79,81-442,444-65535"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"
}

output "nodebalancer_firewall_id" {
  value = linode_firewall.nodebalancer.id
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

# Create ClusterIssuer for Let's Encrypt (HTTP-01 for public services)
# Note: This will be created after cert-manager is deployed via Helmfile
resource "kubectl_manifest" "cluster_issuer" {
  depends_on = [null_resource.wait_for_cert_manager]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = var.tls_email
        privateKeySecretRef = {
          name = "letsencrypt-prod"
        }
        solvers = [
          {
            http01 = {
              ingress = {
                class = "nginx"
              }
            }
          }
        ]
      }
    }
  })
}

# Create ClusterIssuer for Let's Encrypt (DNS-01 for internal services)
resource "kubectl_manifest" "cluster_issuer_dns01" {
  depends_on = [
    null_resource.wait_for_cert_manager,
    kubernetes_secret.cloudflare_api_token
  ]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod-dns01"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = var.tls_email
        privateKeySecretRef = {
          name = "letsencrypt-prod-dns01"
        }
        solvers = [
          {
            dns01 = {
              cloudflare = {
                email = var.tls_email
                apiTokenSecretRef = {
                  name = "cloudflare-api-token"
                  key  = "api-token"
                }
              }
            }
          }
        ]
      }
    }
  })
}

# Cloudflare API Token Secret for DNS-01 challenge
resource "kubernetes_secret" "cloudflare_api_token" {
  depends_on = [null_resource.wait_for_cert_manager]
  metadata {
    name      = "cloudflare-api-token"
    namespace = "infra-cert-manager"
  }

  data = {
    "api-token" = var.cloudflare_api_token
  }
}

# Note: Synapse Admin is now deployed by scripts/create_env
# This keeps tenant-specific resources out of Terraform

# Note: Synapse subdomain ingress for federation (.well-known) is now deployed by scripts/create_env
# This keeps tenant-specific resources out of Terraform

// Helm manages application PVCs; do not pre-create them here to avoid ownership conflicts

# TURN server setup
resource "null_resource" "turn_server_setup" {
  count = data.terraform_remote_state.phase1.outputs.turn_server_enabled ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG=${path.root}/../kubeconfig.${var.env}.yaml
      # Wait for ingress controller to be ready
      kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=ingress-nginx -n infra-ingress --timeout=300s
      
      # Get the external IP of the ingress controller
      EXTERNAL_IP=$(kubectl get svc -n infra-ingress ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
      
      if [ -n "$EXTERNAL_IP" ]; then
        echo "Ingress controller external IP: $EXTERNAL_IP"
        echo "TURN server should be configured with this IP: $EXTERNAL_IP"
      else
        echo "Warning: Could not get external IP for ingress controller"
      fi
    EOT
  }

  depends_on = [data.kubernetes_namespace.db]
}

# Wait for VPN server to be ready before updating Unbound
# This ensures the VPN server has finished provisioning, cloud-init is complete, and services are running
resource "null_resource" "wait_for_vpn_server" {
  triggers = {
    vpn_server_ip = data.terraform_remote_state.phase1.outputs.openvpn_server_ip
  }

  provisioner "local-exec" {
    command = <<-EOT
      VPN_IP="${var.vpn_ssh_host != "" ? var.vpn_ssh_host : data.terraform_remote_state.phase1.outputs.openvpn_server_ip}"

      if [ -z "$VPN_IP" ]; then
        echo "Error: VPN server IP not found in phase1 outputs" >&2
        exit 1
      fi

      echo "Waiting for VPN server $VPN_IP to be fully initialized..."
      max_attempts=60
      attempt=0
      
      while [ $attempt -lt $max_attempts ]; do
        # Check if SSH is available and cloud-init is complete
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o BatchMode=yes root@$VPN_IP bash -c '
          # Check cloud-init status
          if ! cloud-init status 2>/dev/null | grep -q "status: done"; then
            exit 1
          fi
          
          # Check OpenVPN service is running
          if ! systemctl is-active --quiet openvpn@server; then
            exit 1
          fi
          
          # Check Unbound DNS is running (docker-compose)
          if ! docker ps | grep -q unbound; then
            exit 1
          fi
          
          # Check that /opt/unbound/unbound.conf exists (Unbound is configured)
          if [ ! -f /opt/unbound/unbound.conf ]; then
            exit 1
          fi
          
          exit 0
        ' >/dev/null 2>&1; then
          echo "VPN server is fully initialized and ready"
          exit 0
        fi
        attempt=$((attempt + 1))
        echo "Attempt $attempt/$max_attempts: VPN server initialization not complete yet, waiting 10 seconds..."
        sleep 10
      done
      
      echo "Error: VPN server did not complete initialization after $((max_attempts * 10)) seconds" >&2
      exit 1
    EOT
  }
}

# Update VPN server Unbound DNS with ingress controller IP
# This runs after the ingress controller is deployed (via Helmfile)
# Uses Terraform's null_resource to declaratively manage the update
resource "null_resource" "update_vpn_unbound" {
  # Triggers when ingress IP or VPN server IP changes
  triggers = {
    ingress_internal_ip  = data.external.ingress_internal_ip.result.ip
    cluster_node_ip      = data.external.cluster_node_ip.result.ip
    cluster_ip           = local.cluster_ip_address
    vpn_server_ip        = data.terraform_remote_state.phase1.outputs.openvpn_server_ip
    turn_server_ip       = data.terraform_remote_state.phase1.outputs.turn_server_ip
    domain               = var.env_dns_label != "" ? "${var.env_dns_label}.${var.domain}" : "prod.${var.domain}"
    vpn_server_ready     = null_resource.wait_for_vpn_server.id
    is_dev_env           = var.env_dns_label != "" ? "true" : "false"
    internal_dns_version = "2" # Bump to force re-run when adding web subdomain entries
  }

  # Use remote-exec to update Unbound config on VPN server
  # vpn_ssh_host overrides public IP when SSH is blocked (e.g., use tunnel IP 10.8.0.1)
  connection {
    type    = "ssh"
    host    = var.vpn_ssh_host != "" ? var.vpn_ssh_host : data.terraform_remote_state.phase1.outputs.openvpn_server_ip
    user    = "root"
    timeout = "20s"
    agent   = true
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
        set -eu
        NODE_IP="${data.external.cluster_node_ip.result.ip}"
        CLUSTER_IP="${local.cluster_ip_address}"
        VPN_IP="${data.terraform_remote_state.phase1.outputs.openvpn_server_ip}"
        TURN_IP="${data.terraform_remote_state.phase1.outputs.turn_server_ip}"
        DOMAIN="${var.env_dns_label != "" ? "internal.${var.env_dns_label}.${var.domain}" : "prod.${var.domain}"}"
        
        if [ -z "$NODE_IP" ] || [ "$NODE_IP" = "" ] || [ "$NODE_IP" = "null" ]; then
          echo "Error: Cluster node IP is not available" >&2
          exit 1
        fi

        # --- Keep OpenVPN pushed routes aligned with the actual node subnet ---
        # Monitoring (Grafana/Prometheus/Alertmanager) resolves to NODE_IP via Unbound.
        # VPN clients must be pushed a route to the NODE_IP subnet, otherwise these hosts are unreachable.
        NODE_SUBNET="$(echo "$NODE_IP" | awk -F. '{print $1"."$2"."$3".0"}')"
        NODE_ROUTE="$NODE_SUBNET 255.255.255.0"

        if [ ! -f /etc/openvpn/server.conf ]; then
          echo "Error: /etc/openvpn/server.conf not found on VPN server; OpenVPN not installed/configured" >&2
          exit 1
        fi

        # Replace (or add) the node subnet route push. Prefer editing in-place to avoid clobbering cert/key paths.
        if grep -q '^push "route 192\.168\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.0 255\.255\.255\.0"' /etc/openvpn/server.conf; then
          sed -i "s/^push \\\"route 192\\.168\\.[0-9]\\{1,3\\}\\.[0-9]\\{1,3\\}\\.0 255\\.255\\.255\\.0\\\"/push \\\"route $NODE_ROUTE\\\"/" /etc/openvpn/server.conf
        else
          # Insert after the other route pushes if possible; otherwise append.
          if grep -q '^push "route ' /etc/openvpn/server.conf; then
            # Insert after the last push route line
            awk -v newline="push \\\"route $NODE_ROUTE\\\"" '
              BEGIN{added=0}
              {lines[NR]=$0}
              END{
                last=0
                for(i=1;i<=NR;i++){
                  if(lines[i] ~ /^push "route /) last=i
                }
                for(i=1;i<=NR;i++){
                  print lines[i]
                  if(i==last && added==0){
                    print newline
                    added=1
                  }
                }
                if(added==0){
                  print newline
                }
              }' /etc/openvpn/server.conf > /etc/openvpn/server.conf.tmp
            mv /etc/openvpn/server.conf.tmp /etc/openvpn/server.conf
          else
            echo "push \"route $NODE_ROUTE\"" >> /etc/openvpn/server.conf
          fi
        fi

        # NOTE: OpenVPN restart is deferred to the end of this script.
        # If we're connected via VPN tunnel (10.8.0.1), restarting OpenVPN
        # mid-script kills the SSH session. Config file is updated above;
        # restart happens after all other work is complete.

        # Refresh NAT rule for VPN->node-subnet so nodes can reply to VPN clients
        VPN_NET="10.8.0.0/24"
        # Delete any existing MASQUERADE to a 192.168.*.0/24 that we may have previously added
        iptables -t nat -S POSTROUTING | grep -E "\\-s $VPN_NET .*\\-d 192\\.168\\.[0-9]+\\.[0-9]+\\.0/24 .*\\-j MASQUERADE" | while read -r rule; do
          iptables -t nat $(echo "$rule" | sed 's/^-A/-D/') || true
        done
        iptables -t nat -A POSTROUTING -s "$VPN_NET" -d "$NODE_SUBNET/24" -o eth0 -j MASQUERADE
        iptables-save > /etc/iptables/rules.v4

        # Backup current config
        cp /opt/unbound/unbound.conf /opt/unbound/unbound.conf.backup
        
        # Remove any existing records for monitoring services (match any line starting with local-data: containing the service name)
        # This ensures we remove ALL instances, even if there are duplicates
        # Note: Use [[:space:]]* to match optional leading whitespace in the config
        sed -i '/[[:space:]]*local-data:.*grafana\./d' /opt/unbound/unbound.conf
        sed -i '/[[:space:]]*local-data:.*prometheus\./d' /opt/unbound/unbound.conf
        sed -i '/[[:space:]]*local-data:.*alertmanager\./d' /opt/unbound/unbound.conf

        # Remove existing web subdomain records (internal DNS for VPN debugging)
        for subdomain in matrix synapse docs files auth home admin account element webmail calendar jitsi lb1; do
          sed -i "/[[:space:]]*local-data:.*$subdomain\./d" /opt/unbound/unbound.conf
        done

        # Verify we removed all instances (log for debugging if needed)
        GRAFANA_COUNT=$(grep -c 'local-data:.*grafana\.' /opt/unbound/unbound.conf 2>/dev/null || echo "0")
        if [ "$GRAFANA_COUNT" -gt 0 ]; then
          echo "Warning: Found $GRAFANA_COUNT remaining grafana records after deletion" >&2
        fi

        # Build monitoring DNS entries (resolve to NODE_IP for NodePort access)
        DNS_ENTRIES="local-data: \"grafana.$DOMAIN. IN A $NODE_IP\"\\
        local-data: \"prometheus.$DOMAIN. IN A $NODE_IP\"\\
        local-data: \"alertmanager.$DOMAIN. IN A $NODE_IP\""

        # Build web service DNS entries (resolve to CLUSTER_IP = NodeBalancer)
        # These bypass Cloudflare, accessible only via VPN for debugging
        for subdomain in matrix synapse docs files auth home admin account element webmail calendar jitsi lb1; do
          DNS_ENTRIES="$DNS_ENTRIES\\
        local-data: \"$subdomain.$DOMAIN. IN A $CLUSTER_IP\""
        done

        # Add all DNS entries before stub-zone block
        sed -i "/^stub-zone:/i\\
$DNS_ENTRIES
" /opt/unbound/unbound.conf

        # Verify we added exactly one record per monitoring service
        GRAFANA_FINAL=$(grep -c '^local-data:.*grafana\.' /opt/unbound/unbound.conf 2>/dev/null || echo "0")
        if [ "$GRAFANA_FINAL" -ne 1 ]; then
          echo "Error: Expected exactly 1 grafana record, found $GRAFANA_FINAL" >&2
          exit 1
        fi
        
        # Restart Unbound with retries
        max_attempts=5
        attempt=0
        while [ $attempt -lt $max_attempts ]; do
          if cd /opt/unbound && docker-compose restart; then
            echo "Unbound restarted successfully"
            break
          fi
          attempt=$((attempt + 1))
          if [ $attempt -lt $max_attempts ]; then
            echo "Unbound restart failed, attempt $attempt/$max_attempts, retrying in 2 seconds..."
            sleep 2
          else
            echo "Error: Failed to restart Unbound after $max_attempts attempts" >&2
            exit 1
          fi
        done

        # Restart OpenVPN LAST — this may drop the SSH session if connected via VPN tunnel.
        # nohup protects against SIGHUP when the session disconnects.
        echo "Restarting OpenVPN (deferred — session may disconnect briefly)..."
        nohup sh -c 'sleep 1; systemctl restart openvpn@server' >/dev/null 2>&1 &
        echo "All updates applied successfully"
        exit 0
      EOT
    ]
  }

  depends_on = [
    data.kubernetes_namespace.db,
    null_resource.wait_for_vpn_server,
    module.dns_update
  ]
}

# Get pod CIDR range for whitelist (needed when using NodePort with externalTrafficPolicy: Cluster)
# kube-proxy SNATs traffic to pod IPs, so we need to whitelist the pod CIDR range
# Pod CIDRs are per-node, so we use a broader range (10.2.0.0/16) to cover all nodes
data "external" "pod_cidr" {
  program = ["bash", "-c", <<-EOT
    set -e
    # Get all pod CIDRs from nodes
    POD_CIDRS=$(KUBECONFIG=${path.root}/../kubeconfig.${var.env}.yaml kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}' 2>/dev/null || echo "")
    if [ -n "$POD_CIDRS" ] && [ "$POD_CIDRS" != "" ]; then
      # Use broader range 10.2.0.0/16 to cover all node pod CIDRs
      POD_CIDR="10.2.0.0/16"
    else
      # Fallback: use default pod CIDR range
      POD_CIDR="10.2.0.0/16"
    fi
    echo "{\"cidr\": \"$POD_CIDR\"}"
  EOT
  ]
  depends_on = [data.kubernetes_namespace.db]
}

# NOTE: Internal ingress whitelist CIDRs are now managed by Helm via deploy_infra script
# The script computes the CIDRs and passes them to helmfile as environment variables
# This avoids field manager conflicts between Helm and kubectl patch
# See: apps/environments/*/ingress-nginx-internal.yaml.gotmpl

# Query ingress-internal controller service for ClusterIP
# This will fail if the service doesn't exist (phase2 must run after ingress is deployed)
data "external" "ingress_internal_ip" {
  program = ["bash", "-c", <<-EOT
    # Be resilient during destroy: if the service is missing, return empty IP and succeed
    IP=$(KUBECONFIG=${path.root}/../kubeconfig.${var.env}.yaml kubectl get service ingress-nginx-internal-controller -n infra-ingress-internal -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [ -z "$IP" ] || [ "$IP" = "" ]; then
      # Note: Do not fail here to allow terraform destroy to proceed even if ingress is already gone
      echo "{\"ip\": \"\"}"
    else
      echo "{\"ip\": \"$IP\"}"
    fi
  EOT
  ]
  depends_on = [data.kubernetes_namespace.db]
}

# Get cluster node IP (VPC internal IP) for NodePort access
# This is needed because ClusterIPs are not accessible from outside the cluster
# With externalTrafficPolicy: Local and DaemonSet, NodePort works on ALL nodes
# So we can use any node IP (or all of them). We'll use the first node for simplicity.
# If using DaemonSet, all nodes will have the pod, so any node IP will work.
data "external" "cluster_node_ip" {
  program = ["bash", "-c", <<-EOT
    set -e
    # With DaemonSet, all nodes have the ingress controller pod
    # So we can use any node IP. We'll use the first node for simplicity.
    # If you want to use all nodes, return all node IPs and update DNS accordingly.
    NODE_NAME=$(KUBECONFIG=${path.root}/../kubeconfig.${var.env}.yaml kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$NODE_NAME" ] || [ "$NODE_NAME" = "" ]; then
      echo "Error: Could not find any cluster nodes" >&2
      exit 1
    fi
    # Get the internal IP of that node
    NODE_IP=$(KUBECONFIG=${path.root}/../kubeconfig.${var.env}.yaml kubectl get node "$NODE_NAME" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [ -z "$NODE_IP" ] || [ "$NODE_IP" = "" ]; then
      echo "Error: Could not determine internal IP for node $NODE_NAME" >&2
      exit 1
    fi
    echo "{\"ip\": \"$NODE_IP\"}"
  EOT
  ]
  depends_on = [data.kubernetes_namespace.db]
}

# Use exact VPN server VPC/LAN CIDR from phase1 outputs (support subnet)
locals {
  vpn_server_vpc_cidr = data.terraform_remote_state.phase1.outputs.vpn_server_vpc_cidr
  # Compute cluster node subnet (/24) from first node InternalIP (e.g., 192.168.156.0/24)
  cluster_node_subnet_cidr = format("%s.%s.%s.0/24",
    split(".", data.external.cluster_node_ip.result.ip)[0],
    split(".", data.external.cluster_node_ip.result.ip)[1],
    split(".", data.external.cluster_node_ip.result.ip)[2]
  )
  # Compute OpenVPN server eth0 /24 subnet CIDR from its private IP
  openvpn_server_private_ip_octets = split(".", data.terraform_remote_state.phase1.outputs.openvpn_server_private_ip)
  vpn_server_eth0_subnet_cidr = format("%s.%s.%s.0/24",
    local.openvpn_server_private_ip_octets[0],
    local.openvpn_server_private_ip_octets[1],
    local.openvpn_server_private_ip_octets[2]
  )

  # Postfix mynetworks - SECURITY: Only trust specific VPN server IP, not entire datacenter
  # This prevents other Linode customers from abusing our mail relay
  # Components:
  #   - 127.0.0.0/8: localhost
  #   - 10.0.0.0/8: K8s pod network (Cilium)
  #   - 172.16.0.0/12: K8s service network
  #   - VPN server specific IP/32: Only the VPN server can relay through K8s Postfix
  postfix_mynetworks = join(",", [
    "127.0.0.0/8",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "${data.terraform_remote_state.phase1.outputs.openvpn_server_private_ip}/32"
  ])
}

# Note: CoreDNS and internal ingress are managed by Helmfile
# This keeps Terraform focused on infrastructure (DNS, instances, firewalls)

# =============================================================================
# Email/SMTP Configuration (Postfix)
# =============================================================================

# NOTE: DKIM key generation removed - now managed per-tenant by create_env script
# Each tenant provides their own DKIM key in their secrets file

locals {
  # SMTP domain defaults to main domain
  smtp_domain = var.smtp_domain != "" ? var.smtp_domain : var.domain
  # Postfix uses "relay" hostname to avoid conflicts with tenant Stalwart servers
  # Tenant Stalwarts use "mail.<domain>" as their hostname for user-facing SMTP
  # Using the same hostname causes "loops back to myself" errors in mail routing
  smtp_hostname = "relay.${local.smtp_domain}"
}

# Reference mail namespace (infra-mail)
# Created by deploy_infra script before Terraform runs
data "kubernetes_namespace" "mail" {
  count = var.smtp_enabled ? 1 : 0

  metadata {
    name = "infra-mail"
  }
}

# NOTE: DKIM secrets are now created per-tenant by create_env script
# Each tenant's key is stored as dkim-key-<tenant-name> secret

# Postfix configuration ConfigMap
# Based on existing templates in infra/templates/
resource "kubernetes_config_map" "postfix_config" {
  count = var.smtp_enabled ? 1 : 0

  metadata {
    name      = "postfix-config"
    namespace = data.kubernetes_namespace.mail[0].metadata[0].name
  }

  data = {
    # Main Postfix configuration (based on postfix-main.cf.tpl)
    "main.cf" = templatefile("${path.module}/templates/postfix-main.cf.tpl", {
      myhostname = local.smtp_hostname
      mydomain   = local.smtp_domain
      myorigin   = local.smtp_domain
      # SECURITY: Use specific VPN IP, not broad datacenter range
      mynetworks = local.postfix_mynetworks
      # VPN server private IP for SMTP relay - ensures consistent source IP for SPF
      smtp_relay_host = data.terraform_remote_state.phase1.outputs.openvpn_server_private_ip
    })

    # Master process configuration (based on postfix-master.cf)
    "master.cf" = file("${path.module}/templates/postfix-master.cf")

    # Aliases (based on postfix-aliases.tpl)
    "aliases" = templatefile("${path.module}/templates/postfix-aliases.tpl", {
      domain = local.smtp_domain
    })
  }
}

# OpenDKIM configuration ConfigMap
resource "kubernetes_config_map" "opendkim_config" {
  count = var.smtp_enabled ? 1 : 0

  metadata {
    name      = "opendkim-config"
    namespace = data.kubernetes_namespace.mail[0].metadata[0].name
  }

  data = {
    # OpenDKIM configuration (based on opendkim.conf.tpl)
    "opendkim.conf" = templatefile("${path.module}/templates/opendkim.conf.tpl", {
      domain   = local.smtp_domain
      selector = "default"
    })

    # Key table - maps domain to key location (populated by create_env for each tenant)
    "KeyTable" = "# Managed by create_env - tenant keys added dynamically"

    # Signing table - maps sender addresses to key selector (populated by create_env for each tenant)
    "SigningTable" = "# Managed by create_env - tenant domains added dynamically"

    # Trusted hosts - IPs that can send through this server
    "TrustedHosts" = <<-EOT
      127.0.0.1
      localhost
      10.0.0.0/8
      172.16.0.0/12
      192.168.0.0/16
    EOT
  }

  # Preserve tenant DKIM configurations added by create_env
  # KeyTable and SigningTable are dynamically updated per-tenant
  lifecycle {
    ignore_changes = [
      data["KeyTable"],
      data["SigningTable"],
    ]
  }
}

# Postfix init scripts ConfigMap
# Scripts in /docker-init.d/ are executed by boky/postfix after config generation
# but before Postfix starts. This allows us to configure port-specific master.cf settings.
resource "kubernetes_config_map" "postfix_init_scripts" {
  count = var.smtp_enabled ? 1 : 0

  metadata {
    name      = "postfix-init-scripts"
    namespace = data.kubernetes_namespace.mail[0].metadata[0].name
  }

  data = {
    # Configure port-specific security policies via postconf -P
    # Port 25 (smtp): Inbound mail with strict recipient verification (backscatter prevention)
    # Port 587 (submission): Internal apps only, can send to any external address
    "10-master-cf-overrides.sh" = <<-EOT
      #!/bin/sh
      set -e
      echo "Configuring port-specific master.cf overrides..."

      # Port 25 (smtp): Strict recipient verification for inbound mail
      # reject_unverified_recipient probes Stalwart to verify recipients exist
      # reject_unauth_destination prevents open relay
      postconf -P "smtp/inet/smtpd_recipient_restrictions=reject_unverified_recipient,reject_unauth_destination"
      postconf -P "smtp/inet/smtpd_relay_restrictions=reject_unauth_destination"

      # Port 587 (submission): Internal apps only (Keycloak, Alertmanager, Stalwart)
      # permit_mynetworks allows cluster pods to send to any external address
      # This port is only reachable via ClusterIP (not exposed externally)
      postconf -P "submission/inet/smtpd_recipient_restrictions=permit_mynetworks,reject"
      postconf -P "submission/inet/smtpd_relay_restrictions=permit_mynetworks,reject"
      postconf -P "submission/inet/syslog_name=postfix/submission"

      echo "Port-specific master.cf configuration complete"
      postconf -Mf | grep -E "^(smtp|submission)"
    EOT
  }
}

# Postfix Deployment with OpenDKIM sidecar
# Image: boky/postfix (Docker Hub, well-maintained SMTP relay image)
# OpenDKIM: instrumentisto/opendkim (Docker Hub)
resource "kubernetes_deployment" "postfix" {
  count = var.smtp_enabled ? 1 : 0

  metadata {
    name      = "postfix"
    namespace = data.kubernetes_namespace.mail[0].metadata[0].name
    labels = {
      app = "postfix"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "postfix"
      }
    }

    template {
      metadata {
        labels = {
          app = "postfix"
        }
        annotations = {
          # Trigger redeployment when config changes
          "checksum/postfix-config"       = sha256(jsonencode(kubernetes_config_map.postfix_config[0].data))
          "checksum/opendkim-config"      = sha256(jsonencode(kubernetes_config_map.opendkim_config[0].data))
          "checksum/postfix-init-scripts" = sha256(jsonencode(kubernetes_config_map.postfix_init_scripts[0].data))
        }
      }

      spec {
        # OpenDKIM sidecar container
        container {
          name = "opendkim"
          # instrumentisto/opendkim:2.10 - verified Alpine-based OpenDKIM image
          image = "instrumentisto/opendkim:2.10"

          port {
            container_port = 8891
            name           = "milter"
          }

          volume_mount {
            name       = "opendkim-config"
            mount_path = "/etc/opendkim"
            read_only  = true
          }

          # NOTE: Tenant DKIM keys are mounted at /etc/dkim-keys/<tenant>/ by create_env
          # No base mount needed here - each tenant gets their own volume mount

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }
        }

        # Init container to prepare routing hash databases
        # Copies routing files from read-only ConfigMap to writable emptyDir,
        # then runs postmap to generate .db files
        init_container {
          name  = "prepare-routing"
          image = "boky/postfix:v5.1.0"

          command = ["/bin/sh", "-c", <<-EOT
            set -e
            mkdir -p /etc/postfix/tables
            # Copy routing files if they exist (ConfigMap is optional)
            if [ -f /etc/postfix/routing/transport ]; then
              cp /etc/postfix/routing/transport /etc/postfix/tables/transport
              postmap /etc/postfix/tables/transport
              echo "Generated transport.db"
            else
              # Create empty files if ConfigMap doesn't exist yet
              touch /etc/postfix/tables/transport
              postmap /etc/postfix/tables/transport
              echo "Created empty transport.db"
            fi
            
            if [ -f /etc/postfix/routing/relay_domains ]; then
              cp /etc/postfix/routing/relay_domains /etc/postfix/tables/relay_domains
              postmap /etc/postfix/tables/relay_domains
              echo "Generated relay_domains.db"
            else
              touch /etc/postfix/tables/relay_domains
              postmap /etc/postfix/tables/relay_domains
              echo "Created empty relay_domains.db"
            fi
            
            ls -la /etc/postfix/tables/
          EOT
          ]

          volume_mount {
            name       = "postfix-routing"
            mount_path = "/etc/postfix/routing"
            read_only  = true
          }

          volume_mount {
            name       = "postfix-tables"
            mount_path = "/etc/postfix/tables"
          }
        }

        # Postfix main container
        container {
          name = "postfix"
          # boky/postfix:v5.1.0 - SMTP relay image with DKIM support
          # Source: https://github.com/bokysan/docker-postfix
          # v5.1.0 released Jan 2025, supports /docker-init.d/ scripts
          image = "boky/postfix:v5.1.0"

          port {
            container_port = 25
            name           = "smtp"
          }

          port {
            container_port = 587
            name           = "submission"
          }

          # Mount init script for port-specific master.cf configuration
          # Scripts in /docker-init.d/ run after config generation but before Postfix starts
          volume_mount {
            name       = "postfix-init-scripts"
            mount_path = "/docker-init.d"
            read_only  = true
          }

          env {
            name  = "ALLOWED_SENDER_DOMAINS"
            value = var.smtp_allowed_sender_domains
          }

          env {
            name  = "HOSTNAME"
            value = local.smtp_hostname
          }

          # Use external OpenDKIM milter (sidecar)
          env {
            name  = "DKIM_AUTOGENERATE"
            value = "false"
          }

          env {
            name  = "POSTFIX_myhostname"
            value = local.smtp_hostname
          }

          env {
            name  = "POSTFIX_mydomain"
            value = local.smtp_domain
          }

          env {
            name  = "POSTFIX_myorigin"
            value = local.smtp_domain
          }

          env {
            name = "POSTFIX_mynetworks"
            # SECURITY: Use specific VPN IP, not broad datacenter range
            # See local.postfix_mynetworks for details
            value = local.postfix_mynetworks
          }

          # Connect to OpenDKIM sidecar for DKIM signing
          env {
            name  = "POSTFIX_smtpd_milters"
            value = "inet:127.0.0.1:8891"
          }

          env {
            name  = "POSTFIX_non_smtpd_milters"
            value = "inet:127.0.0.1:8891"
          }

          env {
            name  = "POSTFIX_milter_default_action"
            value = "accept"
          }

          env {
            name  = "POSTFIX_milter_protocol"
            value = "6"
          }

          # SMTP relay - forward all mail through VPN server for consistent source IP (SPF)
          env {
            name  = "RELAYHOST"
            value = "[${data.terraform_remote_state.phase1.outputs.openvpn_server_private_ip}]:25"
          }

          # Inbound mail routing - transport_maps and relay_domains
          # These files are managed by deploy-stalwart.sh for each tenant
          # Init container copies them to /etc/postfix/tables/ and runs postmap
          env {
            name  = "POSTFIX_relay_domains"
            value = "hash:/etc/postfix/tables/relay_domains"
          }

          env {
            name  = "POSTFIX_transport_maps"
            value = "hash:/etc/postfix/tables/transport"
          }

          # Override boky/postfix image's default SMTP restrictions
          # The image defaults are designed for send-only, not for relay

          # Allow connections from anyone (we filter at recipient level)
          env {
            name  = "POSTFIX_smtpd_client_restrictions"
            value = "permit"
          }

          # Relay restrictions: allow mynetworks, reject unauthorized destinations
          env {
            name  = "POSTFIX_smtpd_relay_restrictions"
            value = "permit_mynetworks, reject_unauth_destination"
          }

          # Recipient restrictions: use defaults, port-specific overrides are in master.cf
          # Port 25 (smtp): reject_unverified_recipient, reject_unauth_destination (in master.cf)
          # Port 587 (submission): permit_mynetworks, reject (in master.cf)
          # Note: main.cf restrictions serve as fallback if master.cf doesn't override
          env {
            name  = "POSTFIX_smtpd_recipient_restrictions"
            value = "reject_non_fqdn_recipient, reject_unknown_recipient_domain, reject_unauth_destination"
          }

          # Address verification settings - probe downstream to verify recipients exist
          env {
            name  = "POSTFIX_address_verify_poll_count"
            value = "3"
          }
          env {
            name  = "POSTFIX_address_verify_poll_delay"
            value = "3s"
          }
          env {
            name  = "POSTFIX_address_verify_map"
            value = "btree:/var/lib/postfix/verify"
          }
          # Reject permanently (550) for invalid addresses - don't use temp failure (450)
          env {
            name  = "POSTFIX_unverified_recipient_reject_code"
            value = "550"
          }
          env {
            name  = "POSTFIX_unverified_recipient_reject_reason"
            value = "Recipient address rejected: undeliverable address"
          }

          # Sender restrictions: permit all senders (needed for inbound mail from external domains)
          # The Docker image generates restrictive rules from ALLOWED_SENDER_DOMAINS - override them
          # Relay control is handled by smtpd_relay_restrictions, not sender restrictions
          env {
            name  = "POSTFIX_smtpd_sender_restrictions"
            value = "permit"
          }

          volume_mount {
            name       = "postfix-tables"
            mount_path = "/etc/postfix/tables"
            read_only  = false
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }

          # Liveness probe - check SMTP port
          liveness_probe {
            tcp_socket {
              port = 25
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          # Readiness probe
          readiness_probe {
            tcp_socket {
              port = 25
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "postfix-config"
          config_map {
            name = kubernetes_config_map.postfix_config[0].metadata[0].name
          }
        }

        volume {
          name = "opendkim-config"
          config_map {
            name = kubernetes_config_map.opendkim_config[0].metadata[0].name
          }
        }

        # Routing ConfigMap for multi-tenant inbound mail
        # This ConfigMap is created/managed by deploy_infra and deploy-stalwart.sh (not Terraform)
        # Contains transport and relay_domains files that map domains to tenant Stalwarts
        volume {
          name = "postfix-routing"
          config_map {
            name = "postfix-routing"
            # Optional so Postfix still starts if ConfigMap not yet created
            optional = true
          }
        }

        # Writable volume for postmap-generated .db files
        # Init container copies routing files here and generates hash databases
        volume {
          name = "postfix-tables"
          empty_dir {}
        }

        # Init scripts for port-specific master.cf configuration
        # Scripts run via boky/postfix's /docker-init.d/ mechanism
        volume {
          name = "postfix-init-scripts"
          config_map {
            name         = kubernetes_config_map.postfix_init_scripts[0].metadata[0].name
            default_mode = "0755"
          }
        }

        # NOTE: DKIM keys are mounted per-tenant by create_env at /etc/dkim-keys/<tenant>/
        # Each tenant's volume is added via kubectl patch when running create_env
      }
    }
  }

  # Ignore DKIM key volumes added by create_env for each tenant
  # These are managed by create_env, not Terraform, so we must ignore them
  # to prevent Terraform from removing tenant DKIM mounts
  lifecycle {
    ignore_changes = [
      # Tenant DKIM key volumes added by create_env
      spec[0].template[0].spec[0].volume,
      # OpenDKIM container volume mounts for DKIM keys
      spec[0].template[0].spec[0].container[0].volume_mount,
    ]
  }
}

# Postfix ClusterIP Service - internal SMTP access only
resource "kubernetes_service" "postfix" {
  count = var.smtp_enabled ? 1 : 0

  metadata {
    name      = "postfix"
    namespace = data.kubernetes_namespace.mail[0].metadata[0].name
    labels = {
      app = "postfix"
    }
  }

  spec {
    selector = {
      app = "postfix"
    }

    port {
      port        = 25
      target_port = 25
      name        = "smtp"
    }

    type = "ClusterIP"
  }
}

# Postfix NodePort Service - for VPN server to reach K8s Postfix via VPC
# This allows the VPN Postfix to route inbound mail to K8s without going through internet
resource "kubernetes_service" "postfix_nodeport" {
  count = var.smtp_enabled ? 1 : 0

  metadata {
    name      = "postfix-nodeport"
    namespace = data.kubernetes_namespace.mail[0].metadata[0].name
    labels = {
      app = "postfix"
    }
  }

  spec {
    selector = {
      app = "postfix"
    }

    port {
      port        = 25
      target_port = 25
      node_port   = 30025
      name        = "smtp"
    }

    type = "NodePort"

    # Use Cluster policy so NodePort works on any node (pod may move)
    # Source IP will be SNAT'd but that's OK - K8s Postfix trusts 10.0.0.0/8 (pod network)
    # Security is enforced at VPN Postfix level (specific VPN IP in mynetworks)
    external_traffic_policy = "Cluster"
  }
}

# Postfix Internal Service - for internal apps to send via submission port
# This service provides SMTP submission (port 587) without recipient verification
# for trusted internal apps (Keycloak, Alertmanager, Synapse, Stalwart)
resource "kubernetes_service" "postfix_internal" {
  count = var.smtp_enabled ? 1 : 0

  metadata {
    name      = "postfix-internal"
    namespace = data.kubernetes_namespace.mail[0].metadata[0].name
    labels = {
      app = "postfix"
    }
  }

  spec {
    selector = {
      app = "postfix"
    }

    port {
      port        = 587
      target_port = 587
      name        = "submission"
    }

    type = "ClusterIP"
  }
}

# NetworkPolicy: Restrict access to Postfix ports
# - Port 587: Allow from all cluster pods (internal apps)
# - Port 25: Allow all (NodePort traffic will reach this)
resource "kubernetes_network_policy" "postfix_ingress" {
  count = var.smtp_enabled ? 1 : 0

  metadata {
    name      = "postfix-ingress"
    namespace = data.kubernetes_namespace.mail[0].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "postfix"
      }
    }

    policy_types = ["Ingress"]

    # Port 587: submission - allow from all cluster namespaces
    ingress {
      from {
        namespace_selector {}
      }
      ports {
        port     = "587"
        protocol = "TCP"
      }
    }

    # Port 25: smtp - allow all (NodePort traffic will reach this)
    # We can't distinguish NodePort traffic at NetworkPolicy level
    # Security relies on recipient verification at port 25
    ingress {
      ports {
        port     = "25"
        protocol = "TCP"
      }
    }
  }
}

# NOTE: LoadBalancer for Postfix removed due to open relay vulnerability
# Linode's NodeBalancer does SNAT, so externalTrafficPolicy: Local doesn't preserve client IPs
# K8s Postfix is now internal-only (ClusterIP), accessible only from within the cluster
# Inbound mail architecture needs to be redesigned to properly restrict external access

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