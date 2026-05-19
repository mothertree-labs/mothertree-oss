# Variables for phase1-dev. Mirror the subset of phase1 vars that the
# lke-cluster module consumes — passed via the same root-level
# terraform.tfvars + terraform.dev.tfvars files that phase1 uses.

variable "linode_token" {
  description = "Linode API token for authentication"
  type        = string
  sensitive   = true
}

variable "cluster_label" {
  description = "Base label for the LKE cluster (the '-dev' suffix is appended in main.tf)"
  type        = string
  default     = "matrix-cluster"
}

variable "linode_region" {
  description = "Linode region for the cluster (LKE compute region)"
  type        = string
  default     = "us-lax"
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
      type  = "g6-standard-4"
      count = 3
      tags  = ["matrix", "dev", "primary"]
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

variable "common_tags" {
  description = "Common tags to apply to all resources (env tag added automatically)"
  type        = list(string)
  default     = ["matrix", "terraform"]
}

variable "dev_state_bucket_label" {
  description = "Label of the Linode Object Storage bucket used by CI for the dev cluster heartbeat. Must be globally unique within Linode Object Storage."
  type        = string
  default     = "mothertree-dev-state"
}

variable "dev_state_region" {
  description = "Linode region for the dev_state Object Storage bucket and scoped access key. Use the LKE-style region label (e.g. 'us-lax')."
  type        = string
  default     = "us-lax"
}

