locals {
  common_labels = merge(
    {
      env        = var.env
      app        = "estateflow"
      managed_by = "terraform"
    },
    var.extra_labels
  )

  project_services = toset([
    "sqladmin.googleapis.com",
    "redis.googleapis.com",
    "storage.googleapis.com",
    "secretmanager.googleapis.com",
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
    "container.googleapis.com",
  ])

  gke_cluster_name = "${var.env}-estateflow-cluster"
  gke_namespace    = coalesce(var.gke_namespace, "${var.env}-estateflow")
  gke_zone         = coalesce(var.gke_zone, "${var.region}-a")

  redis_transit_encryption = var.redis_tier == "BASIC" ? "DISABLED" : "SERVER_AUTHENTICATION"
}

# -----------------------------------------------------------------------------
# APIs (do not disable project APIs on destroy — avoids breaking other workloads)
# -----------------------------------------------------------------------------
resource "google_project_service" "services" {
  for_each = local.project_services

  service            = each.key
  disable_on_destroy = false
}

# -----------------------------------------------------------------------------
# Optional VPC + Private Service Access for Cloud SQL private IP
# -----------------------------------------------------------------------------
resource "google_compute_network" "private" {
  count = var.enable_private_sql ? 1 : 0

  name                    = "${var.env}-estateflow-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_global_address" "private_service_range" {
  count = var.enable_private_sql ? 1 : 0

  name          = "${var.env}-estateflow-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.private[0].id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  count = var.enable_private_sql ? 1 : 0

  network                 = google_compute_network.private[0].id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_range[0].name]

  depends_on = [
    google_project_service.services["sqladmin.googleapis.com"],
    google_project_service.services["redis.googleapis.com"],
    google_project_service.services["storage.googleapis.com"],
    google_project_service.services["secretmanager.googleapis.com"],
    google_project_service.services["compute.googleapis.com"],
    google_project_service.services["servicenetworking.googleapis.com"],
  ]
}

# -----------------------------------------------------------------------------
# GKE (zonal cluster, separate node pool)
# -----------------------------------------------------------------------------
resource "google_container_cluster" "primary" {
  name     = local.gke_cluster_name
  location = local.gke_zone

  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = var.gke_deletion_protection

  release_channel {
    channel = var.gke_release_channel
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  resource_labels = local.common_labels

  depends_on = [
    google_project_service.services["container.googleapis.com"],
    google_project_service.services["compute.googleapis.com"],
  ]

  lifecycle {
    ignore_changes = [
      node_config,
    ]
  }
}

resource "google_container_node_pool" "primary" {
  name     = "${var.env}-estateflow-pool"
  cluster  = google_container_cluster.primary.name
  location = google_container_cluster.primary.location

  node_count = var.gke_node_count

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.gke_machine_type
    disk_size_gb = var.gke_disk_size_gb
    disk_type    = "pd-standard"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = local.common_labels

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}

# -----------------------------------------------------------------------------
# DB password (generated; never commit secrets — apps read from Secret Manager)
# -----------------------------------------------------------------------------
resource "random_password" "db" {
  length  = 32
  special = false
}

# -----------------------------------------------------------------------------
# GCS bucket
# -----------------------------------------------------------------------------
resource "google_storage_bucket" "bucket" {
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

# -----------------------------------------------------------------------------
# Cloud SQL (PostgreSQL)
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Memorystore Redis
# -----------------------------------------------------------------------------
resource "google_redis_instance" "redis" {
  name           = "${var.env}-estateflow-redis"
  tier           = var.redis_tier
  memory_size_gb = var.redis_memory
  region         = var.region

  auth_enabled            = true
  transit_encryption_mode = local.redis_transit_encryption
  connect_mode            = "DIRECT_PEERING"

  labels = local.common_labels
}

# -----------------------------------------------------------------------------
# Secret Manager (passwords and connection hints for runtime / CI)
# -----------------------------------------------------------------------------
resource "google_secret_manager_secret" "db_password" {
  secret_id = "${var.env}-db-password"

  labels = local.common_labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_password_version" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result

  deletion_policy = "ABANDON"
}

resource "google_secret_manager_secret" "redis_host" {
  secret_id = "${var.env}-redis-host"

  labels = local.common_labels

  replication {
    auto {}
  }
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
}

resource "google_secret_manager_secret_version" "redis_auth_version" {
  secret      = google_secret_manager_secret.redis_auth.id
  secret_data = google_redis_instance.redis.auth_string

  deletion_policy = "ABANDON"
}
