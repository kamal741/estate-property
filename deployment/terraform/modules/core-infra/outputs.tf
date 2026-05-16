output "bucket_name" {
  description = "GCS application bucket name when create_application_gcs_bucket is true; otherwise null (use remote state bucket or add your own storage)."
  value       = var.create_application_gcs_bucket ? google_storage_bucket.bucket[0].name : null
}

output "db_connection_name" {
  description = "Cloud SQL instance connection name (for Cloud SQL Auth Proxy / IAM DB auth)."
  value       = google_sql_database_instance.postgres.connection_name
}

output "db_name" {
  description = "Logical database name on the instance."
  value       = google_sql_database.db.name
}

output "db_user" {
  description = "PostgreSQL user created for the application."
  value       = google_sql_user.user.name
}

output "db_password" {
  description = "Generated PostgreSQL password for db_user. Also stored in Secret Manager (secret_db_password_id). Sensitive."
  value       = random_password.db.result
  sensitive   = true
}

output "redis_auth_string" {
  description = "Memorystore Redis AUTH string. Also stored in Secret Manager (secret_redis_auth_id). Sensitive."
  value       = google_redis_instance.redis.auth_string
  sensitive   = true
}

output "db_public_ip" {
  description = "Public IPv4 of Cloud SQL when private IP is disabled; empty when using private IP only."
  value       = google_sql_database_instance.postgres.public_ip_address
}

output "db_private_ip" {
  description = "Private IPv4 of Cloud SQL when private IP is enabled; empty otherwise."
  value       = google_sql_database_instance.postgres.private_ip_address
}

output "redis_host" {
  description = "Memorystore Redis host (internal)."
  value       = google_redis_instance.redis.host
}

output "redis_port" {
  description = "Memorystore Redis port."
  value       = google_redis_instance.redis.port
}

output "secret_db_password_id" {
  description = "Secret Manager secret id holding the generated DB password."
  value       = google_secret_manager_secret.db_password.secret_id
}

output "secret_redis_host_id" {
  description = "Secret Manager secret id holding the Redis host."
  value       = google_secret_manager_secret.redis_host.secret_id
}

output "secret_redis_auth_id" {
  description = "Secret Manager secret id holding the Redis AUTH string."
  value       = google_secret_manager_secret.redis_auth.secret_id
}

output "vpc_network_name" {
  description = "VPC network name when private SQL is enabled; null otherwise."
  value       = var.enable_private_sql ? google_compute_network.private[0].name : null
}

output "ingress_static_ip_name" {
  description = "Name of the reserved global static IP for GKE Ingress, when reserve_ingress_static_ip is true; use as kubernetes.io/ingress.global-static-ip-name."
  value       = var.reserve_ingress_static_ip ? google_compute_global_address.ingress[0].name : null
}

output "ingress_static_ip_address" {
  description = "IPv4 address of the reserved global static IP for GKE Ingress, when reserve_ingress_static_ip is true."
  value       = var.reserve_ingress_static_ip ? google_compute_global_address.ingress[0].address : null
}

output "gcp_project_id" {
  description = "GCP project ID (for gcloud / CI)."
  value       = var.project_id
}

output "gke_cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.primary.name
}

output "gke_cluster_location" {
  description = "GKE cluster zone (zonal cluster)."
  value       = google_container_cluster.primary.location
}

output "gke_cluster_endpoint" {
  description = "GKE control plane endpoint (without scheme)."
  value       = google_container_cluster.primary.endpoint
}

output "gke_cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate (PEM)."
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "gke_namespace" {
  description = "Kubernetes namespace created in the cluster for application workloads."
  value       = local.gke_namespace
}

output "gke_get_credentials_command" {
  description = "Convenience command to fetch kubeconfig credentials for this cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${google_container_cluster.primary.location} --project ${var.project_id}"
}

output "artifact_registry_repository_id" {
  description = "Artifact Registry Docker repository id (use as ARTIFACT_REGISTRY_REPOSITORY with deploy-platform.sh BUILD_PUSH_JENKINS_IMAGE=1)."
  value       = google_artifact_registry_repository.docker.repository_id
}

output "artifact_registry_region" {
  description = "Region where the Artifact Registry repository lives (same as var.region)."
  value       = google_artifact_registry_repository.docker.location
}

# REGION-docker.pkg.dev/PROJECT/REPO_ID — append /<image_name> for app images (e.g. estateflow-admin-service).
output "artifact_registry_docker_prefix" {
  description = "Docker registry prefix for this env's Artifact Registry repository (no image name or tag)."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.docker.repository_id}"
}

output "jenkins_image_repository" {
  description = "Helm image.repository value for the custom Jenkins image (no tag): REGION-docker.pkg.dev/PROJECT/REPO/jenkins."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.docker.repository_id}/jenkins"
}

output "jenkins_gcp_service_account_email" {
  description = "Jenkins dedicated GCP service account email when enable_jenkins_gcp_service_account is true; null otherwise. Annotate KSA iam.gke.io/gcp-service-account with this value."
  value       = var.enable_jenkins_gcp_service_account ? google_service_account.jenkins[0].email : null
}

output "jenkins_kubernetes_service_account_name" {
  description = "Kubernetes ServiceAccount name configured for Workload Identity (Helm should use serviceAccount.name equal to this)."
  value       = var.jenkins_kubernetes_sa_name
}
