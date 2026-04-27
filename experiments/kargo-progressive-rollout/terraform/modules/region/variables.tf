variable "environment" {
  type        = string
  description = "Deployment environment (integration, stage, production)"
}

variable "sector" {
  type        = string
  description = "Deployment sector within environment (e2e, canary, main)"
}

variable "region" {
  type        = string
  description = "GCP region"
}

variable "module_version" {
  type        = string
  description = "Module version (commit SHA). Updated by Kargo during promotion via hcl-update."
}

variable "cluster_version" {
  type        = string
  description = "GKE cluster version. Updated by Kargo during promotion via hcl-update."
}
