# Project APIs — do not disable on destroy (avoids breaking other workloads).
resource "google_project_service" "services" {
  for_each = local.project_services

  service            = each.key
  disable_on_destroy = false
}
