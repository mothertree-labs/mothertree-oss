# phase1-dev — dev-only LKE cluster and CI heartbeat bucket.
#
# This directory was split out of phase1/ to give the dev cluster its own
# remote-state backend (Linode Object Storage). That backend is what makes the
# Phase 3 on-demand-dev model possible: CI brings the cluster up on demand and
# an idle reaper destroys it, and both code paths need to read/write durable
# shared state from environments that don't have the operator's laptop.
#
# - Prod and prod-eu continue to live in phase1/ with local state on the
#   operator's machine — see CLAUDE.md and phase1/main.tf.
# - The always-up dev VMs (postgres-dev, headscale-dev, turn-server-dev) also
#   continue to live in phase1/ (dev workspace). Only the ephemeral LKE
#   cluster, its VPC/subnet, and the kubeconfig file resource moved here.

provider "linode" {
  token = var.linode_token
}

# LKE cluster — module call mirrors phase1/main.tf for dev so the migration
# (state pull → state rm → import) is a no-op `terraform plan`.
module "lke_cluster" {
  source = "../modules/lke-cluster"

  cluster_label    = "${var.cluster_label}-dev"
  region           = var.linode_region
  k8s_version      = var.linode_k8s_version
  node_pools       = var.linode_node_pools
  tags             = sort(concat(var.common_tags, ["dev"]))
  control_plane_ha = var.linode_control_plane_ha
}

# Kubeconfig written to repo root so deploy_infra / create_env can find it
# with the same path expectations they use for prod / prod-eu.
resource "local_file" "kubeconfig" {
  content  = base64decode(module.lke_cluster.kubeconfig)
  filename = "${path.root}/../kubeconfig.dev.yaml"

  depends_on = [module.lke_cluster]
}

# Linode Object Storage bucket for the dev cluster lifecycle heartbeat
# (last-used.txt). Read by the Phase 3 idle reaper from outside the cluster,
# so it must survive across destroy/recreate cycles of the LKE cluster itself.
resource "linode_object_storage_bucket" "dev_state" {
  region = var.dev_state_region
  label  = var.dev_state_bucket_label
}

# Scoped access key with read/write to the heartbeat bucket only.
# CI writes the heartbeat with this key; the reaper reads it. The key has no
# access to any other bucket (or the Terraform-state bucket).
resource "linode_object_storage_key" "dev_state" {
  label = "tf-managed-${var.dev_state_bucket_label}"

  bucket_access {
    region      = var.dev_state_region
    bucket_name = linode_object_storage_bucket.dev_state.label
    permissions = "read_write"
  }
}
