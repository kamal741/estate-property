variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "region" {
  type        = string
  description = "GCP region for regional resources."
}

variable "create_app_runtime_secrets" {
  type        = bool
  description = "When true, Terraform creates Kubernetes Secrets estateflow-admin-db and estateflow-redis in gke_namespace (username/password and host/redis AUTH)."
  default     = true
}

variable "enable_jenkins_workload_identity" {
  type        = bool
  description = "When true, creates Jenkins GCP SA + IAM in core-infra, and Kubernetes jenkins ServiceAccount + WI annotation + optional namespace admin RoleBinding (matches Helm serviceAccount.name)."
  default     = true
}

variable "jenkins_gcp_sa_account_id" {
  type        = string
  description = "GCP service account_id for Jenkins; null uses module default jenkins-sa-<env>. Set to jenkins-sa if you use one SA per project (avoid two env roots both managing the same id)."
  default     = null
  nullable    = true
}

variable "jenkins_kubernetes_sa_name" {
  type        = string
  description = "Kubernetes ServiceAccount name for Jenkins (must match Helm jenkins chart serviceAccount.name)."
  default     = "jenkins"
}

variable "jenkins_grant_namespace_admin" {
  type        = bool
  description = "When true with enable_jenkins_workload_identity, create a RoleBinding to ClusterRole admin scoped to the app namespace."
  default     = true
}
