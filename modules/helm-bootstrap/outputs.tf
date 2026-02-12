output "release_name" {
  description = "Name of the Helm release"
  value       = helm_release.chart.name
}

output "namespace" {
  description = "Namespace where the chart was deployed"
  value       = helm_release.chart.namespace
}

output "version" {
  description = "Version of the deployed chart"
  value       = helm_release.chart.version
}

output "status" {
  description = "Status of the Helm release"
  value       = helm_release.chart.status
}

output "values" {
  description = "Values used for the deployment"
  value       = helm_release.chart.values
  sensitive   = true
} 