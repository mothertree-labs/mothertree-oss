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

variable "region" {
  description = "Linode region for the PostgreSQL server"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for server access"
  type        = string
  sensitive   = true
}

variable "env" {
  description = "The environment (e.g., prod, dev, prod-eu)"
  type        = string
}

variable "volume_size" {
  description = "Size of the data volume for PostgreSQL in GB"
  type        = number
  default     = 80
  validation {
    condition     = var.volume_size >= 10 && var.volume_size <= 1000
    error_message = "Volume size must be between 10 and 1000 GB."
  }
}

variable "headscale_url" {
  description = "URL of the Headscale instance this VM should join (e.g., https://hs-prod.example.com:8080)"
  type        = string
}

variable "tailscale_auth_key" {
  description = "Pre-authenticated key from Headscale for joining the tailnet"
  type        = string
  sensitive   = true
}

variable "postgres_version" {
  description = "PostgreSQL major version to install"
  type        = string
  default     = "16"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = list(string)
  default     = ["postgres", "database", "terraform"]
}

variable "admin_ssh_cidrs" {
  description = "List of CIDR blocks allowed SSH access. Defaults to empty list which blocks all public SSH."
  type        = list(string)
  default     = []
}
