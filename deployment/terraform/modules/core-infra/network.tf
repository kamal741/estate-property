# -----------------------------------------------------------------------------
# VPC, Private Service Access, GKE subnet, optional Ingress static IP
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

resource "google_compute_subnetwork" "gke" {
  count = var.enable_private_sql ? 1 : 0

  name          = "${var.env}-estateflow-gke-subnet"
  ip_cidr_range = var.gke_subnet_cidr
  region        = var.region
  network       = google_compute_network.private[0].id

  private_ip_google_access = true

  secondary_ip_range {
    range_name    = var.gke_secondary_range_pods_name
    ip_cidr_range = var.gke_pods_cidr
  }

  secondary_ip_range {
    range_name    = var.gke_secondary_range_services_name
    ip_cidr_range = var.gke_services_cidr
  }
}

resource "google_compute_global_address" "ingress" {
  count = var.reserve_ingress_static_ip ? 1 : 0

  name = "${var.env}-estateflow-ingress-ip"
}
