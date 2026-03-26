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

variable "region" {
  description = "Linode region for the Postfix relay server"
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

variable "headscale_url" {
  description = "URL of the Headscale instance this VM should join (e.g., https://hs-prod.example.com:8080)"
  type        = string
}

variable "tailscale_auth_key" {
  description = "Pre-authenticated key from Headscale for joining the tailnet"
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = list(string)
  default     = ["postfix", "mail-relay", "terraform"]
}

variable "admin_ssh_cidrs" {
  description = "List of CIDR blocks allowed SSH access. Defaults to empty list which blocks all public SSH."
  type        = list(string)
  default     = []
}
