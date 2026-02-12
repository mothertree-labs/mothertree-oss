output "cluster_id" {
  description = "The ID of the LKE cluster"
  value       = linode_lke_cluster.cluster.id
}

output "cluster_label" {
  description = "The label of the LKE cluster"
  value       = linode_lke_cluster.cluster.label
}

output "cluster_region" {
  description = "The region of the LKE cluster"
  value       = linode_lke_cluster.cluster.region
}

output "cluster_status" {
  description = "The status of the LKE cluster"
  value       = linode_lke_cluster.cluster.status
}

output "cluster_ip_address" {
  description = "The IP address of the LKE cluster"
  value       = replace(replace(linode_lke_cluster.cluster.api_endpoints[0], "https://", ""), ":443", "")
}

output "cluster_endpoint" {
  description = "The endpoint for the LKE cluster"
  value       = linode_lke_cluster.cluster.api_endpoints[0]
}

output "kubeconfig" {
  description = "Base64 encoded kubeconfig for the LKE cluster"
  value       = linode_lke_cluster.cluster.kubeconfig
  sensitive   = true
}

output "node_pools" {
  description = "Information about the node pools"
  value       = linode_lke_cluster.cluster.pool
}

output "vpc_id" {
  description = "The ID of the VPC"
  value       = linode_vpc.cluster_vpc.id
}

output "vpc_subnet_id" {
  description = "The ID of the VPC subnet"
  value       = linode_vpc_subnet.cluster_subnet.id
}

output "vpc_subnet_range" {
  description = "The IP range of the VPC subnet"
  value       = linode_vpc_subnet.cluster_subnet.ipv4
}
