module "infra" {
  source = "../../modules/core-infra"

  project_id = var.project_id
  region     = var.region
  env        = "dev"

  db_user      = "estateflow_user"
  db_tier      = "db-f1-micro"
  redis_tier   = "BASIC"
  redis_memory = 1

  db_deletion_protection                 = false
  enable_private_sql                     = false
  bucket_force_destroy                   = true
  bucket_noncurrent_version_max_age_days = 30

  gke_machine_type        = "e2-standard-2"
  gke_node_count          = 1
  gke_deletion_protection = false
}

resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = module.infra.gke_namespace

    labels = {
      env        = "dev"
      app        = "estateflow"
      managed_by = "terraform"
    }
  }
}
