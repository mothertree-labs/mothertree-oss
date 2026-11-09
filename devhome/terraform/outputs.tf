output "periscope_ip" {
  description = "Public IPv4 of the periscope — the env's ingress LB IP for DNS"
  value       = linode_instance.periscope.ip_address
}

output "box_ip" {
  description = "Public IPv4 of the rehearsal box (SSH bootstrap only; no public ingress)"
  value       = var.box_enabled ? linode_instance.box[0].ip_address : null
}
