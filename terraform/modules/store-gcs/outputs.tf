output "bucket" {
  description = "Store bucket name (gcs backend `bucket`)."
  value       = local.bucket_name
}

output "share_url" {
  description = "Base URL for share links (gcs backend `shareUrl`), no trailing slash."
  value       = var.custom_domain == null ? trimsuffix(google_cloudfunctions2_function.share.url, "/") : "https://${var.custom_domain}"
}

output "custom_domain" {
  description = "The configured vanity domain, or null."
  value       = var.custom_domain
}

# Records Cloud Run wants published for the mapped domain; empty when there is no
# custom_domain, and unpopulated until the mapping leaves PENDING.
output "custom_domain_dns_records" {
  description = "DNS records to create for custom_domain (name/type/rrdata)."
  value       = local.domain_enabled == 1 ? google_cloud_run_domain_mapping.share[0].status[0].resource_records : []
}

# The service-account JSON key the daemon consumes as `serviceAccountKey`.
# private_key is base64-encoded JSON; decode before use.
output "service_account_key" {
  description = "gcs backend `serviceAccountKey` (JSON)."
  sensitive   = true
  value       = base64decode(google_service_account_key.client.private_key)
}

# This module always wires the notification, so the function is always there to
# consume chunk-delete requests. Constant rather than absent: a client reads the
# same field for either cloud.
output "delete_function" {
  description = "Whether a tsync client may set deleteFunction on this store."
  value       = true
}
