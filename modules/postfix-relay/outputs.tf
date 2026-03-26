output "postfix_relay_ip" {
  description = "Public IP address of the Postfix relay server (for DNS MX records and Ansible provisioning)"
  value       = linode_instance.postfix_relay.ip_address
}

output "postfix_relay_id" {
  description = "ID of the Postfix relay server"
  value       = linode_instance.postfix_relay.id
}

output "postfix_relay_label" {
  description = "Label of the Postfix relay server"
  value       = linode_instance.postfix_relay.label
}
