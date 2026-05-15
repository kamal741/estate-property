output "bucket_name" {
  value = module.infra.bucket_name
}

output "db_connection_name" {
  value = module.infra.db_connection_name
}

output "db_name" {
  value = module.infra.db_name
}

output "db_user" {
  value = module.infra.db_user
}

output "db_public_ip" {
  value = module.infra.db_public_ip
}

output "db_private_ip" {
  value = module.infra.db_private_ip
}

output "redis_host" {
  value = module.infra.redis_host
}

output "redis_port" {
  value = module.infra.redis_port
}

output "secret_db_password_id" {
  value = module.infra.secret_db_password_id
}

output "secret_redis_host_id" {
  value = module.infra.secret_redis_host_id
}

output "secret_redis_auth_id" {
  value = module.infra.secret_redis_auth_id
}

output "vpc_network_name" {
  value = module.infra.vpc_network_name
}

output "ingress_static_ip_name" {
  description = "GKE Ingress static IP resource name (annotation kubernetes.io/ingress.global-static-ip-name)."
  value       = module.infra.ingress_static_ip_name
}

output "ingress_static_ip_address" {
  description = "GKE Ingress static IPv4 (configure DNS to point here)."
  value       = module.infra.ingress_static_ip_address
}

output "gke_cluster_name" {
  value = module.infra.gke_cluster_name
}

output "gke_cluster_location" {
  value = module.infra.gke_cluster_location
}

output "gke_namespace" {
  value = module.infra.gke_namespace
}

output "gke_get_credentials_command" {
  value = module.infra.gke_get_credentials_command
}

output "gcp_project_id" {
  description = "GCP project ID."
  value       = module.infra.gcp_project_id
}

# For Jenkins / CI: cluster, namespaces, and the exact gcloud command to refresh kubeconfig.
output "artifact_registry_repository_id" {
  description = "Artifact Registry repository id (set ARTIFACT_REGISTRY_REPOSITORY when using BUILD_PUSH_JENKINS_IMAGE=1)."
  value       = module.infra.artifact_registry_repository_id
}

output "jenkins_image_repository" {
  description = "Helm Jenkins image.repository (no tag) for images pushed to this env’s AR repo."
  value       = module.infra.jenkins_image_repository
}

output "jenkins_gcp_service_account_email" {
  description = "Jenkins dedicated GCP service account (Workload Identity); null if enable_jenkins_workload_identity is false."
  value       = module.infra.jenkins_gcp_service_account_email
}

output "jenkins_gke_context" {
  description = "Non-secret GKE context for pipelines (use with a GCP SA key or gcloud auth in the agent)."
  value = {
    gcp_project_id                    = module.infra.gcp_project_id
    gke_cluster_name                  = module.infra.gke_cluster_name
    gke_cluster_location              = module.infra.gke_cluster_location
    gke_app_namespace                 = module.infra.gke_namespace
    jenkins_helm_namespace            = module.infra.gke_namespace
    platform_ingress_helm_namespace   = "kube-system"
    gcloud_get_credentials_command    = module.infra.gke_get_credentials_command
    artifact_registry_repository_id   = module.infra.artifact_registry_repository_id
    jenkins_image_repository          = module.infra.jenkins_image_repository
    ingress_static_ip_name            = module.infra.ingress_static_ip_name
    ingress_static_ip_address         = module.infra.ingress_static_ip_address
    jenkins_gcp_service_account_email = module.infra.jenkins_gcp_service_account_email
  }
}
