variable "namespace" {
  type        = string
  description = "Kubernetes namespace for estateflow-admin-db and estateflow-redis."
}

variable "env" {
  type        = string
  description = "Environment label (dev, prod)."
}

variable "db_user" {
  type        = string
  description = "PostgreSQL username (plain text; stored via string_data)."
}

variable "db_password" {
  type        = string
  description = "PostgreSQL password (plain text; stored via string_data)."
  sensitive   = true
}

variable "db_host" {
  type        = string
  description = "Cloud SQL host IP (plain text; stored via string_data)."
}

variable "redis_host" {
  type        = string
  description = "Memorystore Redis host (plain text; stored via string_data)."
}

variable "redis_auth_string" {
  type        = string
  description = "Memorystore Redis AUTH string (plain text; stored via string_data)."
  sensitive   = true
}

variable "credentials_schema" {
  type        = string
  description = "Bump to force secret recreation when storage format changes (string_data only)."
  default     = "string-data-v2"
}
