locals {
  cluster_name = "gcp-hcp-${var.environment}-${var.sector}-${var.region}"
  project_id   = "${var.environment}-reg-${var.region}"
}

output "cluster_name" {
  value = local.cluster_name
}

output "project_id" {
  value = local.project_id
}

output "module_version" {
  value = var.module_version
}

output "cluster_version" {
  value = var.cluster_version
}
