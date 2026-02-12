variable "release_name" {
  description = "Name of the Helm release"
  type        = string
  default     = null
}

variable "chart_name" {
  description = "Name of the Helm chart"
  type        = string
}

variable "chart_repository" {
  description = "URL of the Helm chart repository"
  type        = string
}

variable "chart_version" {
  description = "Version of the Helm chart to deploy"
  type        = string
  default     = null
}

variable "namespace" {
  description = "Kubernetes namespace to deploy the chart in"
  type        = string
}

variable "create_namespace" {
  description = "Whether to create the namespace if it doesn't exist"
  type        = bool
  default     = true
}

variable "timeout" {
  description = "Timeout for the Helm operation"
  type        = number
  default     = 600
}

variable "wait" {
  description = "Whether to wait for the deployment to complete"
  type        = bool
  default     = true
}

variable "atomic" {
  description = "Whether to rollback on failure"
  type        = bool
  default     = true
}

variable "values" {
  description = "Values to pass to the Helm chart"
  type        = any
  default     = {}
}

variable "set_values" {
  description = "Additional values to set via --set"
  type        = map(string)
  default     = {}
}

variable "set_sensitive_values" {
  description = "Additional sensitive values to set via --set"
  type        = map(string)
  default     = {}
  sensitive   = true
} 