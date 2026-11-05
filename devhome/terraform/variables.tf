variable "linode_token" {
  description = "Linode API token"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key installed for root on both instances"
  type        = string
}

variable "operator_ips" {
  description = "Public IPv4 addresses allowed to SSH to the instances (bootstrap / Ansible)"
  type        = list(string)
}

variable "label_prefix" {
  description = "Prefix for instance / firewall labels"
  type        = string
  default     = "devhome"
}

variable "region" {
  description = "Linode region"
  type        = string
  default     = "us-lax"
}

variable "periscope_type" {
  description = "Instance type for the periscope (public L4 forwarder)"
  type        = string
  default     = "g6-nanode-1"
}

variable "box_enabled" {
  description = "Create the Linode stand-in for the home box (false once the real box is at home)"
  type        = bool
  default     = true
}

variable "box_type" {
  description = "Instance type for the rehearsal box (sized like the target home server: 32 GB)"
  type        = string
  default     = "g6-standard-8"
}

variable "mail_tcp_ports" {
  description = "Per-tenant Stalwart TCP ports to expose publicly (smtps, submission, imaps, app ports)"
  type        = list(number)
  default     = []
}

variable "media_udp_ports" {
  description = "Per-tenant Jitsi JVB UDP media ports to expose publicly"
  type        = list(number)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = list(string)
  default     = ["mothertree", "devhome"]
}
