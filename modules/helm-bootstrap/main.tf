terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

# Add Helm repository
resource "helm_release" "chart" {
  name             = var.release_name != null ? var.release_name : var.chart_name
  repository       = var.chart_repository
  chart            = var.chart_name
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = var.create_namespace
  timeout          = var.timeout
  wait             = var.wait
  atomic           = var.atomic
  
  values = [yamlencode(var.values)]
  
  # Set values from set block
  dynamic "set" {
    for_each = var.set_values
    content {
      name  = set.key
      value = set.value
    }
  }
  
  # Set sensitive values
  dynamic "set_sensitive" {
    for_each = var.set_sensitive_values
    content {
      name  = set_sensitive.key
      value = set_sensitive.value
    }
  }
} 