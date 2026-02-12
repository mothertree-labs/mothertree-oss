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
  validation {
    condition = contains([
      "us-east", "us-central", "us-west", "us-southeast", "us-southwest",
      "ca-central", "ap-west", "ap-southeast", "ap-south", "ap-northeast",
      "eu-central", "eu-west", "ap-southeast-1", "us-central-1", "us-lax"
    ], var.linode_region)
    error_message = "Invalid Linode region. Please choose a valid region."
  }
}

variable "linode_k8s_version" {
  description = "Kubernetes version for the LKE cluster"
  type        = string
  default     = "1.34"
  validation {
    condition = can(regex("^1\\.(2[4-9]|3[0-9])$", var.linode_k8s_version))
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
    condition = contains(["linode", "cloudflare"], var.dns_provider)
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
    condition = var.storage_size >= 10 && var.storage_size <= 1000
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
  default     = "g6-standard-2"  # 4GB RAM, 2 vCPU
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
  description = "List of CIDR blocks allowed SSH access to servers. Set to specific admin IPs (e.g., [\"203.0.113.10/32\"]). Defaults to empty list which blocks all public SSH; VPN network (10.8.0.0/24) is always allowed on the TURN server."
  type        = list(string)
  default     = []
}


# OpenVPN Server Configuration
variable "openvpn_label" {
  description = "Label for the OpenVPN server"
  type        = string
  default     = "openvpn-server"
}

variable "openvpn_type" {
  description = "Linode instance type for OpenVPN server"
  type        = string
  default     = "g6-nanode-1"  # 1GB RAM, 1 vCPU - cost effective for VPN
}

variable "openvpn_image" {
  description = "OS image for OpenVPN server"
  type        = string
  default     = "linode/ubuntu22.04"
}

variable "vpn_network_cidr" {
  description = "CIDR block for VPN network"
  type        = string
  default     = "10.8.0.0/24"
}

variable "openvpn_disk_size" {
  description = "Disk size for OpenVPN server in GB"
  type        = number
  default     = 25
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
  default     = "g6-standard-2"  # 4GB RAM, 2 vCPU - sufficient for GUI testing
}

variable "jitsi_tester_region" {
  description = "Linode region for the Jitsi tester instance"
  type        = string
  default     = "us-east"
  validation {
    condition = contains([
      "us-east", "us-central", "us-west", "us-southeast", "us-southwest",
      "ca-central", "ap-west", "ap-southeast", "ap-south", "ap-northeast",
      "eu-central", "eu-west", "ap-southeast-1", "us-central-1", "us-lax"
    ], var.jitsi_tester_region)
    error_message = "Invalid Linode region. Please choose a valid region."
  }
}