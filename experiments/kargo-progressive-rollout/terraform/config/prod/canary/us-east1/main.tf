terraform {
  backend "gcs" {
    bucket = "gcp-hcp-prd-global-terraform-state"
    prefix = "region/canary/us-east1"
  }
}

module "region" {
  source          = "../../../../modules/region"
  environment     = var.environment
  sector          = var.sector
  region          = var.region
  module_version  = var.module_version
  cluster_version = var.cluster_version
}

variable "environment" { type = string }
variable "sector" { type = string }
variable "region" { type = string }
variable "module_version" { type = string }
variable "cluster_version" { type = string }

output "region" {
  value = module.region
}
