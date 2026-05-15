# -----------------------------------------------------------------------------
# GKE — zonal cluster + node pool
# -----------------------------------------------------------------------------

resource "google_container_cluster" "primary" {
  name     = local.gke_cluster_name
  location = local.gke_zone

  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = var.gke_deletion_protection

  network    = var.enable_private_sql ? google_compute_network.private[0].id : null
  subnetwork = var.enable_private_sql ? google_compute_subnetwork.gke[0].id : null

  networking_mode = var.enable_private_sql ? "VPC_NATIVE" : null

  dynamic "ip_allocation_policy" {
    for_each = var.enable_private_sql ? [1] : []
    content {
      cluster_secondary_range_name  = var.gke_secondary_range_pods_name
      services_secondary_range_name = var.gke_secondary_range_services_name
    }
  }

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

# Node pool uses the default Compute Engine service account. These project roles are the usual
# minimum for GKE logging and metrics export (alongside per-repository Artifact Registry reader).
resource "google_project_iam_member" "gke_default_node_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "gke_default_node_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}
