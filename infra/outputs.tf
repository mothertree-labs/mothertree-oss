output "db_namespace" {
  description = "The shared database namespace"
  value       = data.kubernetes_namespace.db.metadata[0].name
}

output "cluster_ip_address" {
  description = "IP address of the LKE cluster"
  value       = local.cluster_ip_address
}

output "turn_server_url" {
  description = "URL for external TURN server"
  value       = data.terraform_remote_state.phase1.outputs.turn_server_enabled ? "turn:${data.terraform_remote_state.phase1.outputs.turn_server_ip}:${var.turn_external_port}" : "disabled"
}

output "turn_server_status" {
  description = "Status of external TURN server deployment"
  value       = data.terraform_remote_state.phase1.outputs.turn_server_enabled ? "deployed" : "disabled"
}

output "infrastructure_summary" {
  description = "Summary of the infrastructure deployment"
  value       = <<-EOT
    Infrastructure deployment completed successfully!
    
    Shared Infrastructure:
    - Database Namespace: ${data.kubernetes_namespace.db.metadata[0].name}
    - Cluster IP: ${local.cluster_ip_address}
    ${data.terraform_remote_state.phase1.outputs.turn_server_enabled ? "- TURN Server: deployed (external)" : "- TURN Server: disabled"}
    
    Infrastructure Namespaces:
    - infra-db (PostgreSQL)
    - infra-auth (Keycloak)
    - infra-monitoring (Prometheus, Grafana)
    - infra-ingress (Public ingress controller)
    - infra-ingress-internal (VPN-only ingress)
    - infra-cert-manager (Certificate management)
    - infra-mail (SMTP server)
    
    Next steps:
    1. Deploy tenants using: ./scripts/create_env --tenant=<name> <env>
    
    Note: Tenant-specific resources (Synapse, Element, Docs, Nextcloud, Jitsi) 
    are deployed per-tenant via create_env script.
  EOT
}
