data "google_project" "current" {
  project_id = var.project_id
}

# Default VPC: Memorystore only when enable_private_sql is false. When true, Redis uses
# google_compute_network.private — do not read "default" (avoids extra API calls and projects without a default VPC).
data "google_compute_network" "default" {
  count = var.enable_private_sql ? 0 : 1
  name  = "default"
}
