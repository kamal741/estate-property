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

resource "kubernetes_secret_v1" "estateflow_admin_db" {
  count = var.create_app_runtime_secrets ? 1 : 0

  metadata {
    name      = "estateflow-admin-db"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels = {
      env        = "prod"
      app        = "estateflow"
      managed_by = "terraform"
    }
    annotations = {
      "estateflow.io/credentials-schema" = "string-data-v2"
    }
  }

  type = "Opaque"

  string_data = {
    username = module.infra.db_user
    password = module.infra.db_password
    host     = module.infra.db_host
  }

  depends_on = [kubernetes_namespace_v1.app]
}

resource "kubernetes_secret_v1" "estateflow_redis" {
  count = var.create_app_runtime_secrets ? 1 : 0

  metadata {
    name      = "estateflow-redis"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels = {
      env        = "prod"
      app        = "estateflow"
      managed_by = "terraform"
    }
    annotations = {
      "estateflow.io/credentials-schema" = "string-data-v2"
    }
  }

  type = "Opaque"

  string_data = {
    host     = module.infra.redis_host
    password = module.infra.redis_auth_string
  }

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
