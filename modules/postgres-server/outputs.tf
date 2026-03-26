output "postgres_server_ip" {
  description = "Public IP address of the PostgreSQL server (for Terraform/Ansible provisioning)"
  value       = linode_instance.postgres_server.ip_address
}

output "postgres_server_id" {
  description = "ID of the PostgreSQL server"
  value       = linode_instance.postgres_server.id
}

output "postgres_server_label" {
  description = "Label of the PostgreSQL server"
  value       = linode_instance.postgres_server.label
}

output "postgres_data_volume_id" {
  description = "ID of the persistent data volume"
  value       = linode_volume.postgres_data.id
}
