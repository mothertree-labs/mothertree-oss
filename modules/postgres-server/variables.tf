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
  # Consumed only by cloud-init (user-data.yaml) on the VM's FIRST boot, and
  # the instance ignores later metadata changes (lifecycle.ignore_changes in
  # modules/postgres-server), so changing this never touches an existing VM.
  # The major that actually runs on every environment is managed by Ansible
  # (pg_version, fed from the private infra config's .postgresql.version).
  # Keep this equal to Ansible's default so a fresh VM is not initialised on
  # an older major than the one Ansible then installs and manages.
  default     = "17"
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
