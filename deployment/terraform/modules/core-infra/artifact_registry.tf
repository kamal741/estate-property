# -----------------------------------------------------------------------------
# Artifact Registry (Docker) — images + repository IAM
# -----------------------------------------------------------------------------

resource "google_artifact_registry_repository" "docker" {
  location      = var.region
  repository_id = local.artifact_registry_repository_id
  description   = "Docker images for estateflow (${var.env})"
  format        = "DOCKER"

  labels = local.common_labels

  depends_on = [google_project_service.services["artifactregistry.googleapis.com"]]
}

resource "google_artifact_registry_repository_iam_member" "gke_nodes_reader" {
  project    = var.project_id
  location   = google_artifact_registry_repository.docker.location
  repository = google_artifact_registry_repository.docker.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

resource "google_artifact_registry_repository_iam_member" "cloud_build_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.docker.location
  repository = google_artifact_registry_repository.docker.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${data.google_project.current.number}@cloudbuild.gserviceaccount.com"
}

resource "google_artifact_registry_repository_iam_member" "extras" {
  for_each = { for i, b in var.artifact_registry_repository_iam_extras : tostring(i) => b }

  project    = var.project_id
  location   = google_artifact_registry_repository.docker.location
  repository = google_artifact_registry_repository.docker.repository_id
  role       = each.value.role
  member     = each.value.member
}

# Project-level (same as: gcloud projects add-iam-policy-binding ... --member=serviceAccount:PROJECT_NUMBER@cloudbuild.gserviceaccount.com --role=roles/artifactregistry.writer)
# Broader than repository_iam above; use if Cloud Build must write to other AR repos in the project.
resource "google_project_iam_member" "cloudbuild_artifactregistry_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${data.google_project.current.number}@cloudbuild.gserviceaccount.com"

  depends_on = [
    google_project_service.services["artifactregistry.googleapis.com"],
    google_project_service.services["cloudbuild.googleapis.com"],
  ]
}
