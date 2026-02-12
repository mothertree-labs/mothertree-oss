output "cluster_id" {
  description = "The ID of the LKE cluster"
  value       = module.lke_cluster.cluster_id
}

output "cluster_label" {
  description = "The label of the LKE cluster"
  value       = module.lke_cluster.cluster_label
}

output "cluster_region" {
  description = "The region of the LKE cluster"
  value       = module.lke_cluster.cluster_region
}

output "cluster_status" {
  description = "The status of the LKE cluster"
  value       = module.lke_cluster.cluster_status
}

output "cluster_ip_address" {
  description = "The IP address of the LKE cluster"
  value       = module.lke_cluster.cluster_ip_address
}

output "kubeconfig" {
  description = "Base64 encoded kubeconfig for the LKE cluster"
  value       = module.lke_cluster.kubeconfig
  sensitive   = true
}

output "kubeconfig_path" {
  description = "Path to the kubeconfig file"
  value       = "${path.root}/../kubeconfig.${var.env}.yaml"
}

output "cluster_endpoint" {
  description = "The endpoint for the LKE cluster"
  value       = module.lke_cluster.cluster_endpoint
}

output "node_pools" {
  description = "Information about the node pools"
  value       = module.lke_cluster.node_pools
}

output "matrix_domain" {
  description = "The Matrix server domain"
  value       = "${var.matrix_subdomain}.${var.domain}"
}

output "element_domain" {
  description = "The Element Web domain"
  value       = "${var.element_subdomain}.${var.domain}"
}

output "next_steps" {
  description = "Instructions for Phase 2 deployment"
  value = <<-EOT
    Phase 1 completed successfully!
    
    Next steps for Phase 2:
    1. The kubeconfig has been automatically saved to:
       ${path.root}/../kubeconfig.${var.env}.yaml
    
    2. Navigate to the phase2 directory:
       cd ${path.root}/../phase2
       
    3. Initialize and apply Phase 2:
       terraform init
       terraform plan
       terraform apply
    
    Matrix will be available at:
    - Synapse: https://${var.matrix_subdomain}.${var.domain}
    - Element: https://${var.element_subdomain}.${var.domain}
  EOT
  sensitive = true
}

output "deployment_summary" {
  description = "Summary of the deployment"
  value = <<-EOT
    Matrix infrastructure deployed successfully!
    
    Cluster Details:
    - Cluster ID: ${module.lke_cluster.cluster_id}
    - Region: ${module.lke_cluster.cluster_region}
    - Status: ${module.lke_cluster.cluster_status}
    - Kubeconfig: ${path.root}/../kubeconfig.${var.env}.yaml
    
    Matrix Domain: ${var.matrix_subdomain}.${var.domain}
    ${var.turn_server_enabled ? "TURN Server: ${linode_instance.turn_server[0].ip_address}" : ""}
    
    Next Steps:
    1. Run 'terraform apply' in phase2/ to deploy Matrix services
    2. Wait for DNS propagation (5-10 minutes)
    3. Access Matrix at https://${var.element_subdomain}.${var.domain}
  EOT
}

# TURN Server Outputs
output "turn_server_enabled" {
  description = "Whether TURN server is enabled"
  value       = var.turn_server_enabled
}

output "turn_server_ip" {
  description = "Public IP address of the TURN server"
  value       = var.turn_server_enabled ? linode_instance.turn_server[0].ip_address : null
}

output "turn_server_private_ip" {
  description = "Private IP address of the TURN server"
  value       = var.turn_server_enabled ? linode_instance.turn_server[0].private_ip_address : null
}

output "turn_server_id" {
  description = "ID of the TURN server"
  value       = var.turn_server_enabled ? linode_instance.turn_server[0].id : null
}

output "turn_server_label" {
  description = "Label of the TURN server"
  value       = var.turn_server_enabled ? linode_instance.turn_server[0].label : null
}

# OpenVPN Server Outputs
output "openvpn_server_ip" {
  description = "Public IP address of the OpenVPN server"
  value       = module.openvpn_server.openvpn_server_ip
}

output "openvpn_server_private_ip" {
  description = "Private IP address of the OpenVPN server"
  value       = module.openvpn_server.openvpn_server_private_ip
}

output "openvpn_server_id" {
  description = "ID of the OpenVPN server"
  value       = module.openvpn_server.openvpn_server_id
}

output "vpn_network_cidr" {
  description = "VPN network CIDR block"
  value       = module.openvpn_server.vpn_network_cidr
}

output "vpn_server_tunnel_ip" {
  description = "VPN server's tunnel IP address (for SSH over VPN)"
  value       = module.openvpn_server.vpn_server_tunnel_ip
}

# VPC/LAN CIDR used by the OpenVPN server NIC (support subnet)
output "vpn_server_vpc_cidr" {
  description = "VPC/LAN CIDR used by the OpenVPN server NIC"
  value       = linode_vpc_subnet.support_subnet.ipv4
}

# Jitsi Tester Outputs
output "jitsi_tester_enabled" {
  description = "Whether Jitsi tester instance is enabled"
  value       = var.jitsi_tester_enabled
}

output "jitsi_tester_ip" {
  description = "Public IP address of the Jitsi tester instance"
  value       = var.jitsi_tester_enabled ? linode_instance.jitsi_tester[0].ip_address : null
}

output "jitsi_tester_ssh_command" {
  description = "SSH command with port forwarding for VNC access"
  value       = var.jitsi_tester_enabled ? "ssh -L 5901:localhost:5901 root@${linode_instance.jitsi_tester[0].ip_address}" : null
}

output "jitsi_tester_id" {
  description = "ID of the Jitsi tester instance"
  value       = var.jitsi_tester_enabled ? linode_instance.jitsi_tester[0].id : null
}

output "jitsi_tester_label" {
  description = "Label of the Jitsi tester instance"
  value       = var.jitsi_tester_enabled ? linode_instance.jitsi_tester[0].label : null
}