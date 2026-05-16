# -----------------------------------------------------------------------------
# Secret Manager — DB password, Redis host/auth (operators / CI)
# -----------------------------------------------------------------------------

resource "google_secret_manager_secret" "db_password" {
  secret_id = "${var.env}-db-password"

  labels = local.common_labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.services["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "db_password_version" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result

  deletion_policy = "ABANDON"
}

resource "google_secret_manager_secret" "db_host" {
  secret_id = "${var.env}-db-host"

  labels = local.common_labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.services["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "db_host_version" {
  secret      = google_secret_manager_secret.db_host.id
  secret_data = local.db_host

  deletion_policy = "ABANDON"
}

resource "google_secret_manager_secret" "redis_host" {
  secret_id = "${var.env}-redis-host"

  labels = local.common_labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.services["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "redis_host_version" {
  secret      = google_secret_manager_secret.redis_host.id
  secret_data = google_redis_instance.redis.host

  deletion_policy = "ABANDON"
}

resource "google_secret_manager_secret" "redis_auth" {
  secret_id = "${var.env}-redis-auth"

  labels = local.common_labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.services["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "redis_auth_version" {
  secret      = google_secret_manager_secret.redis_auth.id
  secret_data = google_redis_instance.redis.auth_string

  deletion_policy = "ABANDON"
}
