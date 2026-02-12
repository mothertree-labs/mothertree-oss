variable "domain" {
  description = "Primary domain for Matrix services"
  type        = string
}

variable "env_dns_label" {
  description = "Environment DNS label to append as middle label (e.g., 'dev' to get sub.dev.domain). Empty for none."
  type        = string
  default     = ""
}

variable "cluster_ip_address" {
  description = "IP address of the LKE cluster"
  type        = string
}

variable "dns_provider" {
  description = "DNS provider to use (linode or cloudflare)"
  type        = string
  validation {
    condition     = contains(["linode", "cloudflare"], var.dns_provider)
    error_message = "DNS provider must be either 'linode' or 'cloudflare'."
  }
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token (required for Cloudflare DNS)"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID (required for Cloudflare DNS)"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = list(string)
  default     = []
}

variable "lb1_subdomain" {
  description = "Subdomain for load balancer A record (e.g. 'lb1.prod')"
  type        = string
  default     = "lb1.prod"
}

variable "matrix_cname" {
  description = "CNAME for Matrix (e.g. 'matrix')"
  type        = string
  default     = "matrix"
}

variable "synapse_cname" {
  description = "CNAME for Synapse (e.g. 'synapse')"
  type        = string
  default     = "synapse"
}

# Optional per-app base domains (fallback to var.domain if null)
variable "docs_domain" {
  description = "Base domain for docs app (defaults to var.domain)"
  type        = string
  default     = null
}

variable "auth_domain" {
  description = "Base domain for auth/keycloak app (defaults to var.domain)"
  type        = string
  default     = null
}

variable "home_domain" {
  description = "Base domain for home app (defaults to var.domain)"
  type        = string
  default     = null
}

variable "matrix_domain" {
  description = "Base domain for matrix apps (defaults to var.domain)"
  type        = string
  default     = null
}

variable "turn_server_ip" {
  description = "IP address of the external TURN server (null if not enabled)"
  type        = string
  default     = null
}

variable "vpn_server_ip" {
  description = "IP address of the OpenVPN server"
  type        = string
  default     = null
}

# NOTE: Email DNS variables (dkim_selector, dkim_public_key, node_external_ips) removed
# Email DNS (SPF/DKIM/DMARC) is now managed per-tenant by create_env script

# ingress_lb_ip removed - TURN server uses NodePort directly
# mail_lb_ip removed - inbound mail now handled by VPN server (vpn_server_ip)