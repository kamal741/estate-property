# -----------------------------------------------------------------------------
# Optional GCS bucket for application assets (not Terraform state).
# -----------------------------------------------------------------------------

resource "google_storage_bucket" "bucket" {
  count = var.create_application_gcs_bucket ? 1 : 0

  name          = "${var.env}-estateflow-bucket"
  location      = var.region
  force_destroy = var.bucket_force_destroy

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  labels = local.common_labels

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      days_since_noncurrent_time = var.bucket_noncurrent_version_max_age_days
    }
  }

  lifecycle_rule {
    action {
      type = "AbortIncompleteMultipartUpload"
    }
    condition {
      age = 7
    }
  }
}
