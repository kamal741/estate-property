data "google_project" "current" {
  project_id = var.project_id
}

# Default VPC: Memorystore (and implicit default GKE network) when enable_private_sql is false.
data "google_compute_network" "default" {
  name = "default"
}
