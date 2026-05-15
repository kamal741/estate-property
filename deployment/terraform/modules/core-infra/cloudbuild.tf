# -----------------------------------------------------------------------------
# Cloud Build default staging bucket (gs://<project_id>_cloudbuild)
# -----------------------------------------------------------------------------
# `gcloud builds submit` uploads the build context to this bucket. Some callers
# (e.g. Cloud Shell) resolve reads with the default Compute Engine service
# account, which otherwise lacks storage.objects.get on that object path.

resource "google_storage_bucket_iam_member" "cloudbuild_staging_default_compute_object_user" {
  count = var.grant_default_compute_sa_cloudbuild_staging_iam ? 1 : 0

  bucket = coalesce(var.cloudbuild_staging_bucket_name, "${var.project_id}_cloudbuild")
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"

  depends_on = [
    google_project_service.services["cloudbuild.googleapis.com"],
    google_project_service.services["storage.googleapis.com"],
  ]
}
