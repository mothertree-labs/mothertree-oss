# LKE outputs are guarded with `length(module.lke_cluster) > 0` so the dev
# workspace (where the module count is 0 — see phase1/main.tf) can `terraform
# apply` cleanly. Dev's LKE cluster lives in ../phase1-dev/ and exposes the
# same outputs from there.

output "cluster_id" {
  description = "The ID of the LKE cluster"
  value       = length(module.lke_cluster) > 0 ? module.lke_cluster[0].cluster_id : null
}

output "cluster_label" {
  description = "The label of the LKE cluster"
  value       = length(module.lke_cluster) > 0 ? module.lke_cluster[0].cluster_label : null
}

output "cluster_region" {
  description = "The region of the LKE cluster"
  value       = length(module.lke_cluster) > 0 ? module.lke_cluster[0].cluster_region : null
}

output "cluster_status" {
  description = "The status of the LKE cluster"
  value       = length(module.lke_cluster) > 0 ? module.lke_cluster[0].cluster_status : null
}

output "cluster_ip_address" {
  description = "The IP address of the LKE cluster"
  value       = length(module.lke_cluster) > 0 ? module.lke_cluster[0].cluster_ip_address : null
}

output "kubeconfig" {
  description = "Base64 encoded kubeconfig for the LKE cluster"
  value       = length(module.lke_cluster) > 0 ? module.lke_cluster[0].kubeconfig : null
  sensitive   = true
}

output "kubeconfig_path" {
  description = "Path to the kubeconfig file"
  value       = "${path.root}/../kubeconfig.${var.env}.yaml"
}

output "cluster_endpoint" {
  description = "The endpoint for the LKE cluster"
  value       = length(module.lke_cluster) > 0 ? module.lke_cluster[0].cluster_endpoint : null
}

output "node_pools" {
  description = "Information about the node pools"
  value       = length(module.lke_cluster) > 0 ? module.lke_cluster[0].node_pools : null
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
  value       = <<-EOT
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
  sensitive   = true
}

output "deployment_summary" {
  description = "Summary of the deployment"
  value = length(module.lke_cluster) == 0 ? "LKE cluster managed in ../phase1-dev/ — see that directory's outputs." : format(
    "Matrix infrastructure deployed successfully!\n\nCluster Details:\n- Cluster ID: %s\n- Region: %s\n- Status: %s\n- Kubeconfig: %s/../kubeconfig.%s.yaml\n\nMatrix Domain: %s.%s\n%s\n\nNext Steps:\n1. Run 'terraform apply' in phase2/ to deploy Matrix services\n2. Wait for DNS propagation (5-10 minutes)\n3. Access Matrix at https://%s.%s\n",
    module.lke_cluster[0].cluster_id,
    module.lke_cluster[0].cluster_region,
    module.lke_cluster[0].cluster_status,
    path.root,
    var.env,
    var.matrix_subdomain,
    var.domain,
    var.turn_server_enabled ? "TURN Server: ${linode_instance.turn_server[0].ip_address}" : "",
    var.element_subdomain,
    var.domain,
  )
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

# Headscale Server Outputs
output "headscale_server_ip" {
  description = "Public IP address of the Headscale server"
  value       = var.headscale_enabled ? module.headscale_server[0].headscale_server_ip : null
}

output "headscale_server_id" {
  description = "ID of the Headscale server"
  value       = var.headscale_enabled ? module.headscale_server[0].headscale_server_id : null
}

output "headscale_api_url" {
  description = "Headscale API/coordination URL"
  value       = var.headscale_enabled ? module.headscale_server[0].headscale_api_url : null
}

# PostgreSQL Server Outputs
output "postgres_server_ip" {
  description = "Public IP address of the PostgreSQL server (for provisioning only — DB traffic goes through Tailscale)"
  value       = var.postgres_enabled ? module.postgres_server[0].postgres_server_ip : null
}

output "postgres_server_id" {
  description = "ID of the PostgreSQL server"
  value       = var.postgres_enabled ? module.postgres_server[0].postgres_server_id : null
}

output "postgres_server_label" {
  description = "Label of the PostgreSQL server"
  value       = var.postgres_enabled ? module.postgres_server[0].postgres_server_label : null
}
