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
  description = "When true, creates a VPC + private service connection and Cloud SQL uses private IP only (no public IPv4). GKE is placed VPC-natively on a dedicated subnet in that network; Memorystore uses the same VPC."
  default     = false
}

variable "gke_subnet_cidr" {
  type        = string
  description = "Primary IPv4 CIDR for the regional GKE subnet (node IPs). Only used when enable_private_sql is true. Must not overlap secondary ranges or the PSA allocation."
  default     = "10.10.0.0/20"
}

variable "gke_pods_cidr" {
  type        = string
  description = "Secondary IP range for GKE Pods (VPC-native). Only used when enable_private_sql is true."
  default     = "10.20.0.0/16"
}

variable "gke_services_cidr" {
  type        = string
  description = "Secondary IP range for GKE Services (VPC-native). Only used when enable_private_sql is true. Must not overlap the node subnet, pods range, or the /16 reserved for Private Service Access (servicenetworking); 10.30.0.0/20 often conflicts with an auto-allocated PSA block."
  default     = "10.40.0.0/20"
}

variable "gke_secondary_range_pods_name" {
  type        = string
  description = "Name of the secondary range for Pods on the GKE subnet (must match ip_allocation_policy.cluster_secondary_range_name)."
  default     = "pods-range"
}

variable "gke_secondary_range_services_name" {
  type        = string
  description = "Name of the secondary range for Services on the GKE subnet (must match ip_allocation_policy.services_secondary_range_name)."
  default     = "services-range"
}

variable "reserve_ingress_static_ip" {
  type        = bool
  description = "When true, reserves a global static IPv4 for GKE Ingress (kubernetes.io/ingress.global-static-ip-name). Incurrs a small charge while reserved."
  default     = true
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
# Jenkins (GCP SA + Workload Identity binding on GCP side)
# ---------------------------------------------------------------------------
variable "enable_jenkins_gcp_service_account" {
  type        = bool
  description = "When true, creates a GCP service account for Jenkins with AR/GKE/Storage/Cloud Build project roles, default-compute SA user, and WI principal for <gke_namespace>/<jenkins_kubernetes_sa_name>."
  default     = false
}

variable "jenkins_gcp_sa_account_id" {
  type        = string
  description = "GCP service account account_id (prefix of email). If null, uses jenkins-sa-<env> so dev and prod stacks can coexist in one project without clashing."
  default     = null
  nullable    = true
}

variable "jenkins_gcp_sa_display_name" {
  type        = string
  description = "Optional display name for the Jenkins GCP service account."
  default     = null
  nullable    = true
}

variable "jenkins_kubernetes_sa_name" {
  type        = string
  description = "Kubernetes ServiceAccount name that Jenkins uses (Helm chart default: jenkins). Must match Workload Identity binding member."
  default     = "jenkins"
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

# Optional extra bindings on the Docker repository only (e.g. user:...@... for local docker push).
variable "artifact_registry_repository_iam_extras" {
  type = list(object({
    member = string
    role   = string
  }))
  description = "Additional Artifact Registry repository IAM members (e.g. [{ member = \"user:you@example.com\", role = \"roles/artifactregistry.writer\" }]). Core bindings (GKE nodes reader, Cloud Build writer) are always managed separately."
  default     = []

  validation {
    condition = alltrue([
      for b in var.artifact_registry_repository_iam_extras :
      can(regex("^(user:|serviceAccount:|group:)", b.member))
    ])
    error_message = "Each extra member must use a full principal prefix: user:, serviceAccount:, or group:."
  }
}

# ---------------------------------------------------------------------------
# Cloud Build (default staging bucket IAM)
# ---------------------------------------------------------------------------
variable "grant_default_compute_sa_cloudbuild_staging_iam" {
  type        = bool
  description = "When true, grants roles/storage.objectUser on the Cloud Build default staging bucket to the default Compute Engine SA (needed for gcloud builds submit from Cloud Shell when that identity reads staged sources). Set false if the bucket does not exist yet (Terraform apply will 404); create it with any Cloud Build run, then re-enable."
  default     = true
}

variable "cloudbuild_staging_bucket_name" {
  type        = string
  description = "GCS bucket name for Cloud Build source staging (default: <project_id>_cloudbuild). Override if your org uses a different default bucket name."
  default     = null
  nullable    = true
}
