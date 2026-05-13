variable "project_id" {
  type        = string
  description = "GCP project ID where resources are created."
}

variable "region" {
  type        = string
  description = "Default GCP region for regional resources (Cloud SQL, Redis, bucket location)."
}

variable "env" {
  type        = string
  description = "Short environment name (e.g. dev, prod). Used in resource names and labels."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "env must be one of: dev, staging, prod."
  }
}

variable "db_user" {
  type        = string
  description = "PostgreSQL application user name created on the Cloud SQL instance."
}

variable "db_tier" {
  type        = string
  description = "Cloud SQL machine type (e.g. db-f1-micro, db-g1-small)."
  default     = "db-f1-micro"
}

variable "db_deletion_protection" {
  type        = bool
  description = "When true, Terraform cannot destroy the Cloud SQL instance until protection is disabled."
  default     = true
}

variable "enable_private_sql" {
  type        = bool
  description = "When true, creates a VPC + private service connection and Cloud SQL uses private IP only (no public IPv4)."
  default     = false
}

variable "redis_tier" {
  type        = string
  description = "Memorystore Redis tier: BASIC or STANDARD_HA."
  default     = "BASIC"

  validation {
    condition     = contains(["BASIC", "STANDARD_HA"], var.redis_tier)
    error_message = "redis_tier must be BASIC or STANDARD_HA."
  }
}

variable "redis_memory" {
  type        = number
  description = "Memorystore Redis memory size in GB."
  default     = 1
}

variable "create_application_gcs_bucket" {
  type        = bool
  description = "When true, creates a separate GCS bucket <env>-estateflow-bucket for application assets. When false (default), only the Terraform remote state bucket is used (created by deploy-platform.sh / init); no second bucket."
  default     = false
}

variable "bucket_force_destroy" {
  type        = bool
  description = "When true, allows Terraform to delete a non-empty application bucket (including versioned objects). Use false in production. Only applies when create_application_gcs_bucket is true."
  default     = false
}

variable "bucket_noncurrent_version_max_age_days" {
  type        = number
  description = "Delete noncurrent object versions older than this many days (requires versioning)."
  default     = 90
}

variable "extra_labels" {
  type        = map(string)
  description = "Optional extra labels merged into all supported resources."
  default     = {}
}

# ---------------------------------------------------------------------------
# GKE
# ---------------------------------------------------------------------------
variable "gke_zone" {
  type        = string
  description = "GCP zone for the GKE cluster (e.g. us-central1-a). Defaults to <region>-a when null."
  default     = null
}

variable "gke_machine_type" {
  type        = string
  description = "Machine type for the primary GKE node pool."
  default     = "e2-standard-2"
}

variable "gke_node_count" {
  type        = number
  description = "Node count in the primary GKE node pool."
  default     = 1
}

variable "gke_disk_size_gb" {
  type        = number
  description = "Boot disk size for GKE nodes (GB)."
  default     = 50
}

variable "gke_release_channel" {
  type        = string
  description = "GKE release channel: RAPID, REGULAR, STABLE, or UNSPECIFIED."
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE", "UNSPECIFIED"], var.gke_release_channel)
    error_message = "gke_release_channel must be RAPID, REGULAR, STABLE, or UNSPECIFIED."
  }
}

variable "gke_deletion_protection" {
  type        = bool
  description = "When true, Terraform cannot destroy the GKE cluster until protection is disabled."
  default     = true
}

variable "gke_namespace" {
  type        = string
  description = "Kubernetes namespace name. Defaults to <env>-estateflow when null."
  default     = null
}

# ---------------------------------------------------------------------------
# Artifact Registry (Docker)
# ---------------------------------------------------------------------------
variable "artifact_registry_repository_id" {
  type        = string
  description = "Artifact Registry Docker repository id. Leave unset to use estateflow-<env> so dev and prod can share one GCP project without a repository id clash."
  default     = null
  nullable    = true
}
