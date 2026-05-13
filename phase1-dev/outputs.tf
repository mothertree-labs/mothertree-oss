# Outputs surfaced to scripts/manage_infra so they can be written into
# terraform-outputs.dev.env (consumed by deploy_infra and CI).

output "cluster_id" {
  description = "The ID of the LKE cluster"
  value       = module.lke_cluster.cluster_id
}

output "cluster_label" {
  description = "The label of the LKE cluster"
  value       = module.lke_cluster.cluster_label
}

output "cluster_region" {
  description = "The region of the LKE cluster"
  value       = module.lke_cluster.cluster_region
}

output "cluster_status" {
  description = "The status of the LKE cluster"
  value       = module.lke_cluster.cluster_status
}

output "cluster_ip_address" {
  description = "The IP address of the LKE cluster"
  value       = module.lke_cluster.cluster_ip_address
}

output "cluster_endpoint" {
  description = "The endpoint for the LKE cluster"
  value       = module.lke_cluster.cluster_endpoint
}

output "node_pools" {
  description = "Information about the node pools"
  value       = module.lke_cluster.node_pools
}

output "kubeconfig" {
  description = "Base64 encoded kubeconfig for the LKE cluster"
  value       = module.lke_cluster.kubeconfig
  sensitive   = true
}

output "kubeconfig_path" {
  description = "Path to the kubeconfig file written by local_file.kubeconfig"
  value       = local_file.kubeconfig.filename
}

output "vpc_id" {
  description = "The ID of the LKE VPC (preserved across destroy-dev-cluster cycles)"
  value       = module.lke_cluster.vpc_id
}

output "vpc_subnet_id" {
  description = "The ID of the LKE VPC subnet (destroyed by destroy-dev-cluster, recreated on next bring-up)"
  value       = module.lke_cluster.vpc_subnet_id
}

# CI heartbeat bucket — surfaced into terraform-outputs.dev.env so dev-heartbeat.sh
# and the Phase 3 reaper can authenticate against Linode Object Storage.

output "dev_state_bucket" {
  description = "Linode Object Storage bucket label used for the on-demand-dev heartbeat file"
  value       = linode_object_storage_bucket.dev_state.label
}

output "dev_state_endpoint" {
  description = "Linode Object Storage endpoint hostname for the dev_state bucket"
  value       = linode_object_storage_bucket.dev_state.hostname
}

output "dev_state_access_key" {
  description = "Scoped access key (read_write on dev_state bucket only)"
  value       = linode_object_storage_key.dev_state.access_key
  sensitive   = true
}

output "dev_state_secret_key" {
  description = "Scoped secret key (read_write on dev_state bucket only)"
  value       = linode_object_storage_key.dev_state.secret_key
  sensitive   = true
}
