module "infra" {
  source = "../../modules/core-infra"

  project_id = var.project_id
  region     = var.region
  env        = "prod"

  db_user      = "estateflow_user"
  db_tier      = "db-g1-small"
  redis_tier   = "STANDARD_HA"
  redis_memory = 5

  db_deletion_protection                 = true
  enable_private_sql                     = true
  bucket_force_destroy                   = false
  bucket_noncurrent_version_max_age_days = 90

  gke_machine_type        = "e2-standard-4"
  gke_node_count          = 3
  gke_deletion_protection = true
}

resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = module.infra.gke_namespace

    labels = {
      env        = "prod"
      app        = "estateflow"
      managed_by = "terraform"
    }
  }
}
