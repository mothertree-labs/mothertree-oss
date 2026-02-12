variable "kubeconfig_path" {
  description = "Path to the kubeconfig file from Phase 1"
  type        = string
  default     = "../kubeconfig.yaml"
}

variable "env" {
  description = "Deployment environment label (e.g., prod, dev)"
  type        = string
}

variable "env_dns_label" {
  description = "DNS environment middle label (e.g., 'dev' to get sub.dev.domain). Empty for prod."
  type        = string
  default     = ""
}

# Note: Tenant namespace prefix is now handled by scripts/create_env
# Terraform only manages shared infrastructure (infra-* namespaces)

variable "domain" {
  description = "Primary domain for Matrix services"
  type        = string
  default     = "example.com"
}

variable "matrix_subdomain" {
  description = "Subdomain for Matrix Synapse server"
  type        = string
  default     = "matrix"
}

variable "admin_subdomain" {
  description = "Subdomain for Synapse admin interface"
  type        = string
  default     = "synapse"
}

variable "turn_server_ip" {
  description = "IP address of the external TURN server"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = list(string)
  default     = []
}

variable "element_subdomain" {
  description = "Subdomain for Element Web client"
  type        = string
  default     = "element"
}

variable "tls_email" {
  description = "Email address for Let's Encrypt certificates"
  type        = string
  sensitive   = true
}

variable "matrix_server_name" {
  description = "Matrix server name (usually the domain)"
  type        = string
  default     = "example.com"
}

variable "matrix_report_stats" {
  description = "Whether to report usage statistics to Matrix.org"
  type        = bool
  default     = false
}

variable "matrix_enable_registration" {
  description = "Whether to enable user registration"
  type        = bool
  default     = false
}

variable "matrix_admin_users" {
  description = "List of admin user IDs"
  type        = list(string)
  default     = []
}

variable "matrix_registration_shared_secret" {
  description = "Shared secret for admin API user registration"
  type        = string
  sensitive   = true
}

variable "postgres_enabled" {
  description = "Whether to deploy PostgreSQL in-cluster"
  type        = bool
  default     = true
}

variable "postgres_host" {
  description = "PostgreSQL host (if not using in-cluster)"
  type        = string
  default     = ""
}

variable "postgres_port" {
  description = "PostgreSQL port"
  type        = number
  default     = 5432
}

variable "postgres_database" {
  description = "PostgreSQL database name"
  type        = string
  default     = "synapse"
}

variable "postgres_username" {
  description = "PostgreSQL username"
  type        = string
  default     = "synapse"
}

variable "postgres_password" {
  description = "PostgreSQL password"
  type        = string
  sensitive   = true
}

variable "redis_enabled" {
  description = "Whether to deploy Redis in-cluster"
  type        = bool
  default     = true
}

variable "redis_host" {
  description = "Redis host (if not using in-cluster)"
  type        = string
  default     = ""
}

variable "redis_port" {
  description = "Redis port"
  type        = number
  default     = 6379
}

variable "redis_password" {
  description = "Redis password"
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
}

# TURN server configuration
variable "turn_shared_secret" {
  description = "Shared secret for TURN server authentication"
  type        = string
  sensitive   = true
}

variable "turn_external_port" {
  description = "External port for TURN server (UDP/TCP)"
  type        = number
  default     = 3478
}

variable "turn_alt_port" {
  description = "Alternative port for TURN server (UDP/TCP)"
  type        = number
  default     = 3479
}

variable "turn_realm" {
  description = "TURN server realm"
  type        = string
  default     = "matrix"
}

variable "ingress_class" {
  description = "Ingress class to use"
  type        = string
  default     = "nginx"
}

variable "ingress_annotations" {
  description = "Additional annotations for ingress resources"
  type        = map(string)
  default = {
    "kubernetes.io/ingress.class" = "nginx"
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

variable "linode_token" {
  description = "Linode API token (required for reverse DNS configuration)"
  type        = string
  sensitive   = true
}

# =============================================================================
# SMTP/Email Configuration (Postfix)
# =============================================================================

variable "smtp_enabled" {
  description = "Whether to deploy the Postfix SMTP server for sending emails"
  type        = bool
  default     = true
}

variable "smtp_domain" {
  description = "Domain for SMTP server (defaults to main domain if empty)"
  type        = string
  default     = ""
}

# NOTE: dkim_selector variable removed - DKIM now managed per-tenant by create_env

variable "smtp_relay_networks" {
  description = "Networks allowed to relay through Postfix (CIDR notation, comma-separated)"
  type        = string
  default     = "127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
}

variable "smtp_allowed_sender_domains" {
  description = "Domains allowed to send email through Postfix (comma-separated). Must include all tenant domains."
  type        = string
  default     = "example.com"
}

variable "vpn_ssh_host" {
  description = "SSH host for VPN server provisioners. Defaults to public IP; set to VPN tunnel IP (e.g. 10.8.0.1) when SSH to public IP is blocked."
  type        = string
  default     = ""
}
