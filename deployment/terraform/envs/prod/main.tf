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

  enable_jenkins_gcp_service_account = var.enable_jenkins_workload_identity
  jenkins_gcp_sa_account_id          = var.jenkins_gcp_sa_account_id
  jenkins_kubernetes_sa_name         = var.jenkins_kubernetes_sa_name

  artifact_registry_repository_iam_extras = var.artifact_registry_repository_iam_extras
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

module "app_runtime_secrets" {
  source = "../../modules/app-runtime-secrets"
  count  = var.create_app_runtime_secrets ? 1 : 0

  providers = {
    kubernetes = kubernetes
  }

  namespace         = kubernetes_namespace_v1.app.metadata[0].name
  env               = "prod"
  db_user           = module.infra.db_user
  db_password       = module.infra.db_password
  db_host           = module.infra.db_host
  redis_host        = module.infra.redis_host
  redis_auth_string = module.infra.redis_auth_string

  depends_on = [kubernetes_namespace_v1.app]
}

resource "kubernetes_service_account_v1" "jenkins" {
  count = var.enable_jenkins_workload_identity ? 1 : 0

  metadata {
    name      = var.jenkins_kubernetes_sa_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels = {
      env        = "prod"
      app        = "jenkins"
      managed_by = "terraform"
    }
    annotations = {
      "iam.gke.io/gcp-service-account" = module.infra.jenkins_gcp_service_account_email
    }
  }

  depends_on = [kubernetes_namespace_v1.app]
}

resource "kubernetes_role_binding_v1" "jenkins_namespace_admin" {
  count = var.enable_jenkins_workload_identity && var.jenkins_grant_namespace_admin ? 1 : 0

  metadata {
    name      = "jenkins-admin-binding"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.jenkins_kubernetes_sa_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  depends_on = [kubernetes_service_account_v1.jenkins]
}
