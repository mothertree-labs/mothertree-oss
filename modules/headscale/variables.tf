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

variable "region" {
  description = "Linode region for the Headscale server"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for server access"
  type        = string
  sensitive   = true
}

variable "env" {
  description = "The environment (e.g., prod, dev)"
  type        = string
}

variable "domain" {
  description = "FQDN for the Headscale server (e.g., hs-prod.example.com)"
  type        = string
}

variable "base_domain" {
  description = "Base domain for MagicDNS (must differ from server_url hostname, e.g., ts.example.com)"
  type        = string
}

variable "headscale_version" {
  description = "Headscale version to install"
  type        = string
  default     = "0.28.0"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = list(string)
  default     = ["headscale", "tailnet", "terraform"]
}

variable "admin_ssh_cidrs" {
  description = "List of CIDR blocks allowed SSH access. Defaults to empty list which blocks all public SSH."
  type        = list(string)
  default     = []
}

