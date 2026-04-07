variable "linode_token" {
  description = "Linode API token"
  type        = string
  sensitive   = true
}

variable "ci_label" {
  description = "Label for the CI server instance"
  type        = string
  default     = "mothertree-ci"
}

variable "ci_instance_type" {
  description = "Linode instance type for CI server"
  type        = string
  default     = "g6-standard-4"
}

variable "region" {
  description = "Linode region for CI server"
  type        = string
  default     = "us-lax"
}

variable "ssh_public_key" {
  description = "SSH public key for server access"
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = list(string)
  default     = ["mothertree", "ci"]
}

variable "vpc_subnet_id" {
  description = "ID of the VPC support subnet (from phase1 output or Linode dashboard)"
  type        = number
}

variable "ci_vpc_ip" {
  description = "CI server's static VPC IP on the support subnet"
  type        = string
  default     = "192.168.1.3"
}

