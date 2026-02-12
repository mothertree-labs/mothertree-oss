output "openvpn_server_ip" {
  description = "Public IP address of the OpenVPN server"
  value       = linode_instance.openvpn_server.ip_address
}

output "openvpn_server_private_ip" {
  description = "Private IP address of the OpenVPN server"
  value       = linode_instance.openvpn_server.private_ip_address
}

output "openvpn_server_id" {
  description = "ID of the OpenVPN server"
  value       = linode_instance.openvpn_server.id
}

output "openvpn_server_label" {
  description = "Label of the OpenVPN server"
  value       = linode_instance.openvpn_server.label
}

output "vpn_network_cidr" {
  description = "VPN network CIDR block"
  value       = var.vpn_network_cidr
}

output "vpn_server_tunnel_ip" {
  description = "VPN server's tunnel IP address (first usable IP in vpn_network_cidr)"
  value       = cidrhost(var.vpn_network_cidr, 1)
}

output "openvpn_pki_volume_id" {
  description = "ID of the persistent PKI volume"
  value       = linode_volume.openvpn_pki.id
}

output "mx_mail_host_fqdn" {
  description = "FQDN for the MX mail host (matches rDNS)"
  # domain from phase1 is prod.example.com or dev.example.com
  value = "mail.${replace(var.domain, "^prod\\.", "")}"
}
