variable "cluster_label" {
  description = "Label for the LKE cluster"
  type        = string
}

variable "region" {
  description = "Linode region for the cluster"
  type        = string
}

variable "k8s_version" {
  description = "Kubernetes version for the LKE cluster"
  type        = string
}

variable "node_pools" {
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
}

variable "tags" {
  description = "Tags to apply to the cluster"
  type        = list(string)
  default     = []
}

variable "control_plane_ha" {
  description = "Enable High Availability for the control plane (costs more)."
  type        = bool
  default     = false
}

