output "ci_server_ip" {
  description = "Public IP address of the CI server"
  value       = linode_instance.ci_server.ip_address
}

output "ci_server_vpc_ip" {
  description = "VPC IP address of the CI server"
  value       = var.ci_vpc_ip
}

output "ci_server_id" {
  description = "Linode instance ID of the CI server"
  value       = linode_instance.ci_server.id
}
