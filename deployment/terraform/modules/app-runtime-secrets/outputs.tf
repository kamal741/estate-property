output "estateflow_admin_db_secret_name" {
  value       = kubernetes_secret_v1.estateflow_admin_db.metadata[0].name
  description = "Kubernetes secret name for DB credentials (username, password, host)."
}

output "estateflow_redis_secret_name" {
  value       = kubernetes_secret_v1.estateflow_redis.metadata[0].name
  description = "Kubernetes secret name for Redis credentials (host, password)."
}
