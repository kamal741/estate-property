provider "google" {
  project = var.project_id
  region  = var.region
}

# Token used by the kubernetes provider; refreshed each plan/apply.
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.infra.gke_cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.infra.gke_cluster_ca_certificate)
}
