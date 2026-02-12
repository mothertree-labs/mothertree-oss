output "lb1_a_record_id" {
  description = "ID of the lb1.prod.example.com A record"
  value       = cloudflare_record.lb1_a[0].id
}

# NOTE: Tenant subdomain outputs (matrix_cname_id, synapse_cname_id) removed
# Tenant DNS records are now managed by create_env script, not Terraform
