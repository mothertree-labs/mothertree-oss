terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
    dns = {
      source  = "hashicorp/dns"
      version = "~> 3.0"
    }
  }
}

# Create the LKE cluster
resource "linode_lke_cluster" "cluster" {
  label       = var.cluster_label
  k8s_version = var.k8s_version
  region      = var.region
  # Linode API/provider may return tags in a different order; sort to avoid noisy diffs.
  tags = sort(var.tags)

  # IMPORTANT:
  # If Linode autoscaler is enabled on a pool, Linode will change the *current* pool size
  # (pool.count) outside Terraform. If Terraform manages pool.count, plans will constantly
  # try to revert the pool back to the configured value (fighting autoscaling).
  #
  # We deliberately ignore drift in pool.count so autoscaling can work without noisy plans.
  # NOTE: ignore_changes requires static paths (no splats).
  lifecycle {
    ignore_changes = [
      pool[0].count,
    ]
  }

  # Node pools - defined inline as required by provider
  dynamic "pool" {
    for_each = var.node_pools
    content {
      type  = pool.value.type
      count = pool.value.count
      # Linode API/provider may return pool tags in a different order; sort to avoid noisy diffs.
      tags = sort(pool.value.tags)

      dynamic "autoscaler" {
        for_each = pool.value.autoscaler != null ? [pool.value.autoscaler] : []
        content {
          min = autoscaler.value.min
          max = autoscaler.value.max
        }
      }
    }
  }

  # Control plane HA (configurable; default off to save cost)
  control_plane {
    high_availability = var.control_plane_ha
  }
}

# Create a VPC for private networking
resource "linode_vpc" "cluster_vpc" {
  label       = "${var.cluster_label}-vpc"
  region      = var.region
  description = "VPC for Matrix LKE cluster"
}

# Create VPC subnet for Kubernetes nodes
resource "linode_vpc_subnet" "cluster_subnet" {
  vpc_id = linode_vpc.cluster_vpc.id
  label  = "${var.cluster_label}-subnet"
  ipv4   = "192.168.64.0/18" # 192.168.64.0 - 192.168.127.255 (16k IPs)
} 