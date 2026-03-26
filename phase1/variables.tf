variable "linode_token" {
  description = "Linode API token for authentication"
  type        = string
  sensitive   = true
}

variable "cluster_label" {
  description = "Label for the LKE cluster"
  type        = string
  default     = "matrix-cluster"
}

variable "env" {
  description = "Deployment environment label (e.g., prod, dev)"
  type        = string
  default     = "prod"
}

variable "env_dns_label" {
  description = "DNS environment label inserted as middle label (e.g., 'dev' for sub.dev.domain). Empty for none."
  type        = string
  default     = ""
}

variable "linode_region" {
  description = "Linode region for the cluster"
  type        = string
  default     = "us-lax"
  # No validation — Linode adds regions regularly, let the API reject invalid ones
}

variable "linode_k8s_version" {
  description = "Kubernetes version for the LKE cluster"
  type        = string
  default     = "1.34"
  validation {
    condition     = can(regex("^1\\.(2[4-9]|3[0-9])$", var.linode_k8s_version))
    error_message = "Kubernetes version must be between 1.24 and 1.39."
  }
}

variable "linode_control_plane_ha" {
  description = "Enable High Availability for the LKE control plane (costs more)."
  type        = bool
  default     = false
}


variable "linode_node_pools" {
  description = "List of node pools for the LKE cluster. Each pool can optionally include an autoscaler configuration."
  type = list(object({
    type  = string
    count = number
    tags  = list(string)
    autoscaler = optional(object({
      min = number
      max = number
    }))
  }))
  default = [
    {
      type  = "g6-standard-2"
      count = 3
      tags  = ["matrix", "production"]
    }
  ]
  validation {
    condition = alltrue([
      for pool in var.linode_node_pools : pool.count >= 1 && pool.count <= 10
    ])
    error_message = "Node pool count must be between 1 and 10."
  }
  validation {
    condition = alltrue([
      for pool in var.linode_node_pools : pool.autoscaler == null || (
        pool.autoscaler.min >= 1 &&
        pool.autoscaler.max >= pool.autoscaler.min &&
        pool.autoscaler.max <= 10
      )
    ])
    error_message = "Autoscaler min must be >= 1, max must be >= min, and max must be <= 10."
  }
}

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

variable "element_subdomain" {
  description = "Subdomain for Element Web client"
  type        = string
  default     = "element"
}

variable "dns_provider" {
  description = "DNS provider to use (linode or cloudflare)"
  type        = string
  default     = "cloudflare"
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

variable "storage_enabled" {
  description = "Whether to create block storage volumes"
  type        = bool
  default     = true
}

variable "storage_size" {
  description = "Size of block storage volume in GB"
  type        = number
  default     = 20
  validation {
    condition     = var.storage_size >= 10 && var.storage_size <= 1000
    error_message = "Storage size must be between 10 and 1000 GB."
  }
}

# Common tags
variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = list(string)
  default     = ["matrix", "production", "terraform"]
}

# TURN Server Configuration
variable "turn_server_enabled" {
  description = "Whether to deploy a dedicated TURN server"
  type        = bool
  default     = true
}

variable "turn_server_type" {
  description = "Linode instance type for TURN server"
  type        = string
  default     = "g6-standard-2" # 4GB RAM, 2 vCPU
}

variable "turn_server_image" {
  description = "OS image for TURN server"
  type        = string
  default     = "linode/ubuntu22.04"
}

variable "turn_server_label" {
  description = "Label for the TURN server"
  type        = string
  default     = "turn-server"
}

variable "ssh_public_key" {
  description = "SSH public key for server access"
  type        = string
  sensitive   = true
}

variable "admin_ssh_cidrs" {
  description = "List of CIDR blocks allowed SSH access to servers. Set to specific admin IPs (e.g., [\"203.0.113.10/32\"]). Defaults to empty list which blocks all public SSH; VPN network is always allowed on the TURN server."
  type        = list(string)
  default     = []
}



# Jitsi Tester Configuration
variable "jitsi_tester_enabled" {
  description = "Whether to deploy a Jitsi tester instance (GUI with VNC for testing)"
  type        = bool
  default     = false
}

variable "jitsi_tester_label" {
  description = "Label for the Jitsi tester instance"
  type        = string
  default     = "jitsi-tester"
}

variable "jitsi_tester_type" {
  description = "Linode instance type for Jitsi tester"
  type        = string
  default     = "g6-standard-2" # 4GB RAM, 2 vCPU - sufficient for GUI testing
}

variable "jitsi_tester_region" {
  description = "Linode region for the Jitsi tester instance"
  type        = string
  default     = "us-east"
  # No validation — Linode adds regions regularly, let the API reject invalid ones
}

# Headscale Server Configuration
variable "headscale_enabled" {
  description = "Whether to deploy a Headscale server (self-hosted Tailscale control plane)"
  type        = bool
  default     = false
}

variable "headscale_label" {
  description = "Label for the Headscale server"
  type        = string
  default     = "headscale"
}

variable "headscale_type" {
  description = "Linode instance type for Headscale server"
  type        = string
  default     = "g6-nanode-1" # 1GB RAM, 1 vCPU - sufficient for coordination server
}

variable "headscale_image" {
  description = "OS image for Headscale server"
  type        = string
  default     = "linode/ubuntu24.04"
}

variable "headscale_version" {
  description = "Headscale version to install"
  type        = string
  default     = "0.28.0"
}

variable "headscale_domain" {
  description = "FQDN for the Headscale server (e.g., hs-prod.example.com)"
  type        = string
  default     = ""
}

variable "headscale_base_domain" {
  description = "Base domain for MagicDNS (e.g., ts.example.com)"
  type        = string
  default     = ""
}

# PostgreSQL Server Configuration
variable "postgres_enabled" {
  description = "Whether to deploy a dedicated PostgreSQL VM (replaces in-cluster Bitnami PostgreSQL)"
  type        = bool
  default     = false
}

variable "postgres_label" {
  description = "Label for the PostgreSQL server"
  type        = string
  default     = "postgres"
}

variable "postgres_type" {
  description = "Linode instance type for PostgreSQL server (Dedicated CPU recommended)"
  type        = string
  default     = "g6-dedicated-2" # Dedicated 4GB RAM, 2 vCPU ($36/mo)
}

variable "postgres_image" {
  description = "OS image for PostgreSQL server"
  type        = string
  default     = "linode/ubuntu24.04"
}

variable "postgres_version" {
  description = "PostgreSQL major version to install"
  type        = string
  default     = "16"
}

variable "postgres_volume_size" {
  description = "Size of the PostgreSQL data volume in GB"
  type        = number
  default     = 80
  validation {
    condition     = var.postgres_volume_size >= 10 && var.postgres_volume_size <= 1000
    error_message = "PostgreSQL volume size must be between 10 and 1000 GB."
  }
}

variable "headscale_url" {
  description = "URL of the Headscale instance for Tailscale mesh (e.g., https://hs-prod.example.com:8080)"
  type        = string
  default     = ""
}

variable "tailscale_auth_key" {
  description = "Pre-authenticated key from Headscale for infrastructure nodes to join the tailnet"
  type        = string
  sensitive   = true
  default     = ""
}

# Postfix Relay Server Configuration
variable "postfix_relay_enabled" {
  description = "Whether to deploy a Postfix relay VM on the Tailscale mesh (replaces VPN server mail relay)"
  type        = bool
  default     = false
}

variable "postfix_relay_label" {
  description = "Label for the Postfix relay server"
  type        = string
  default     = "postfix-relay"
}

variable "postfix_relay_type" {
  description = "Linode instance type for Postfix relay server"
  type        = string
  default     = "g6-nanode-1" # 1GB RAM, 1 vCPU ($5/mo) — sufficient for mail relay
}

variable "postfix_relay_image" {
  description = "OS image for Postfix relay server"
  type        = string
  default     = "linode/ubuntu24.04"
}