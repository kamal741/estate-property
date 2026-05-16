# App runtime secrets for estateflow-admin-service Helm chart (secretKeyRef names are fixed).
#
# IMPORTANT: use string_data only. Do NOT use data { key = base64encode(...) } — that double-encodes
# when combined with manual kubectl patches or provider quirks; pods then see values like cG9zdGdyZXM=
# instead of postgres.

resource "terraform_data" "credentials_schema" {
  input = var.credentials_schema
}

resource "kubernetes_secret_v1" "estateflow_admin_db" {
  provider = kubernetes

  metadata {
    name      = "estateflow-admin-db"
    namespace = var.namespace
    labels = {
      env        = var.env
      app        = "estateflow"
      managed_by = "terraform"
    }
    annotations = {
      "estateflow.io/credentials-schema" = var.credentials_schema
    }
  }

  type = "Opaque"

  string_data = {
    username = var.db_user
    password = var.db_password
    host     = var.db_host
  }

  lifecycle {
    precondition {
      condition     = var.db_host != ""
      error_message = "db_host is empty; Cloud SQL must have a private or public IP before creating estateflow-admin-db."
    }
    replace_triggered_by = [
      terraform_data.credentials_schema,
    ]
  }
}

resource "kubernetes_secret_v1" "estateflow_redis" {
  provider = kubernetes

  metadata {
    name      = "estateflow-redis"
    namespace = var.namespace
    labels = {
      env        = var.env
      app        = "estateflow"
      managed_by = "terraform"
    }
    annotations = {
      "estateflow.io/credentials-schema" = var.credentials_schema
    }
  }

  type = "Opaque"

  string_data = {
    host     = var.redis_host
    password = var.redis_auth_string
  }

  lifecycle {
    precondition {
      condition     = var.redis_host != ""
      error_message = "redis_host is empty; Memorystore must be provisioned before creating estateflow-redis."
    }
    replace_triggered_by = [
      terraform_data.credentials_schema,
    ]
  }
}
