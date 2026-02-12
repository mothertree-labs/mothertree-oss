variable "openvpn_label" {
  description = "Label for the OpenVPN server"
  type        = string
  default     = "openvpn-server"
}

variable "openvpn_type" {
  description = "Linode instance type for OpenVPN server"
  type        = string
  default     = "g6-nanode-1" # 1GB RAM, 1 vCPU - cost effective for VPN
}

variable "openvpn_image" {
  description = "OS image for OpenVPN server"
  type        = string
  default     = "linode/ubuntu22.04"
}

variable "region" {
  description = "Linode region for the OpenVPN server"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for server access"
  type        = string
  sensitive   = true
}

variable "vpn_network_cidr" {
  description = "CIDR block for VPN network"
  type        = string
  default     = "10.8.0.0/24"
}

variable "cluster_ip" {
  description = "Kubernetes cluster IP address"
  type        = string
}

variable "dns_server_ip" {
  description = "Internal DNS server IP address"
  type        = string
}

variable "domain" {
  description = "Domain for internal services"
  type        = string
  default     = "prod.example.com"
}

variable "disk_size" {
  description = "Disk size for OpenVPN server in GB"
  type        = number
  default     = 25
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = list(string)
  default     = ["openvpn", "vpn", "terraform"]
}

variable "vpc_id" {
  description = "VPC ID to attach the OpenVPN server to"
  type        = string
  default     = null
}

variable "vpc_subnet_id" {
  description = "VPC subnet ID for the OpenVPN server"
  type        = string
  default     = null
}

variable "env" {
  description = "The environment (e.g., prod, dev)"
  type        = string
}

variable "service_cidr" {
  description = "Kubernetes service CIDR (for ClusterIP routing)"
  type        = string
}

variable "cluster_subnet_cidr" {
  description = "Cluster node subnet CIDR (where cluster nodes are located)"
  type        = string
}

variable "vpn_server_subnet_cidr" {
  description = "VPN server subnet CIDR (where VPN server is located)"
  type        = string
}

variable "cluster_node_ip" {
  description = "Cluster node internal IP address (for routing service CIDR)"
  type        = string
}

variable "cluster_vpc_cidr" {
  description = "Cluster VPC subnet in CIDR format (for firewall rules) - DEPRECATED, use cluster_node_cidr"
  type        = string
  default     = ""
}

variable "cluster_node_cidr" {
  description = "CIDR range that contains cluster node IPs (for firewall rules). Determined dynamically from actual node IPs."
  type        = string
}

variable "admin_ssh_cidrs" {
  description = "List of CIDR blocks allowed SSH access. Set to specific admin IPs (e.g., [\"203.0.113.10/32\"]). Defaults to empty list which blocks all public SSH."
  type        = list(string)
  default     = []
}
