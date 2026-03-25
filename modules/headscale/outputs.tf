output "headscale_server_ip" {
  description = "Public IP address of the Headscale server"
  value       = linode_instance.headscale_server.ip_address
}

output "headscale_server_id" {
  description = "ID of the Headscale server"
  value       = linode_instance.headscale_server.id
}

output "headscale_server_label" {
  description = "Label of the Headscale server"
  value       = linode_instance.headscale_server.label
}

output "headscale_api_url" {
  description = "Headscale API/coordination URL (used by Tailscale clients with --login-server)"
  value       = "https://${var.domain}:8080"
}

output "headscale_derp_url" {
  description = "DERP relay URL (TCP 443 on the Headscale server)"
  value       = "https://${var.domain}:443"
}

output "headscale_data_volume_id" {
  description = "ID of the persistent data volume"
  value       = linode_volume.headscale_data.id
}
