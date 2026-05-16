# -----------------------------------------------------------------------------
# Jenkins — optional GCP SA, project IAM, Workload Identity binding
# -----------------------------------------------------------------------------

resource "google_service_account" "jenkins" {
  count = var.enable_jenkins_gcp_service_account ? 1 : 0

  account_id   = local.jenkins_gcp_sa_account_id_resolved
  display_name = var.jenkins_gcp_sa_display_name != null ? var.jenkins_gcp_sa_display_name : "Jenkins Service Account (${var.env})"
  description  = "Jenkins: Cloud Build, Artifact Registry, GKE, storage; use with Workload Identity in ${local.gke_namespace}."
}

resource "google_project_iam_member" "jenkins_sa" {
  for_each = var.enable_jenkins_gcp_service_account ? local.jenkins_project_roles : toset([])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.jenkins[0].email}"
}

resource "google_service_account_iam_member" "jenkins_sa_service_account_user_on_compute_default" {
  count = var.enable_jenkins_gcp_service_account ? 1 : 0

  service_account_id = "projects/${var.project_id}/serviceAccounts/${data.google_project.current.number}-compute@developer.gserviceaccount.com"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.jenkins[0].email}"
}

resource "google_service_account_iam_member" "jenkins_workload_identity_user" {
  count = var.enable_jenkins_gcp_service_account ? 1 : 0

  service_account_id = google_service_account.jenkins[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${local.gke_namespace}/${var.jenkins_kubernetes_sa_name}]"

  # WI principal only exists after the GKE cluster creates the project workload identity pool.
  depends_on = [google_container_cluster.primary]
}

# Read DB/Redis secrets in Secret Manager (README / operator workflows) without broad project roles.
resource "google_secret_manager_secret_iam_member" "jenkins_operator_secrets" {
  for_each = var.enable_jenkins_gcp_service_account ? {
    db_password = google_secret_manager_secret.db_password.id
    db_host     = google_secret_manager_secret.db_host.id
    redis_host  = google_secret_manager_secret.redis_host.id
    redis_auth  = google_secret_manager_secret.redis_auth.id
  } : {}

  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.jenkins[0].email}"
}
