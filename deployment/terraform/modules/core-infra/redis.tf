# -----------------------------------------------------------------------------
# Memorystore Redis
# -----------------------------------------------------------------------------

resource "google_redis_instance" "redis" {
  name           = "${var.env}-estateflow-redis"
  tier           = var.redis_tier
  memory_size_gb = var.redis_memory
  region         = var.region

  authorized_network = var.enable_private_sql ? google_compute_network.private[0].id : data.google_compute_network.default.id

  auth_enabled            = true
  transit_encryption_mode = local.redis_transit_encryption
  connect_mode            = "DIRECT_PEERING"

  labels = local.common_labels
}
