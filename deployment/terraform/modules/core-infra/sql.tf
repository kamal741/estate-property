# -----------------------------------------------------------------------------
# Cloud SQL (PostgreSQL) + generated DB password
# -----------------------------------------------------------------------------

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "google_sql_database_instance" "postgres" {
  name             = "${var.env}-estateflow-db"
  database_version = "POSTGRES_15"
  region           = var.region

  deletion_protection = var.db_deletion_protection

  settings {
    tier = var.db_tier

    user_labels = local.common_labels

    maintenance_window {
      day          = 7
      hour         = 3
      update_track = "stable"
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00"
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = var.env == "prod" ? 14 : 7
        retention_unit   = "COUNT"
      }
    }

    ip_configuration {
      ipv4_enabled    = !var.enable_private_sql
      private_network = var.enable_private_sql ? google_compute_network.private[0].self_link : null
      ssl_mode        = "ENCRYPTED_ONLY"
    }
  }
}

resource "google_sql_database" "db" {
  name     = "estateflow"
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_user" "user" {
  name     = var.db_user
  instance = google_sql_database_instance.postgres.name
  password = random_password.db.result
}
