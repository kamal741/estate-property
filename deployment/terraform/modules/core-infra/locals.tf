locals {
  # JDBC / psql host: prefer private IP when set (avoid coalesce+nullif — fails on some Terraform/provider evals).
  db_private_ip_resolved = google_sql_database_instance.postgres.private_ip_address
  db_public_ip_resolved  = google_sql_database_instance.postgres.public_ip_address
  db_host = local.db_private_ip_resolved != "" ? local.db_private_ip_resolved : local.db_public_ip_resolved

  common_labels = merge(
    {
      env        = var.env
      app        = "estateflow"
      managed_by = "terraform"
    },
    var.extra_labels
  )

  project_services = toset([
    # Core
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",

    # Compute & networking
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",

    # GKE
    "container.googleapis.com",

    # Databases
    "sqladmin.googleapis.com",
    "redis.googleapis.com",

    # Storage & secrets
    "storage.googleapis.com",
    "secretmanager.googleapis.com",

    # Artifact Registry
    "artifactregistry.googleapis.com",

    # Cloud Build
    "cloudbuild.googleapis.com",
  ])

  gke_cluster_name = "${var.env}-estateflow-cluster"
  gke_namespace    = coalesce(var.gke_namespace, "${var.env}-estateflow")
  gke_zone         = coalesce(var.gke_zone, "${var.region}-a")

  redis_transit_encryption = var.redis_tier == "BASIC" ? "DISABLED" : "SERVER_AUTHENTICATION"

  artifact_registry_repository_id = coalesce(var.artifact_registry_repository_id, "estateflow-${var.env}")

  jenkins_gcp_sa_account_id_resolved = coalesce(var.jenkins_gcp_sa_account_id, "jenkins-sa-${var.env}")

  jenkins_project_roles = toset([
    "roles/artifactregistry.writer",
    "roles/container.developer",
    "roles/storage.admin",
    "roles/cloudbuild.builds.editor",
  ])
}
