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

# A-record value for the custom domain (point custom_domain here). null when no
# custom_domain. The managed cert provisions once this A record resolves.
output "custom_domain_ip" {
  description = "Load balancer IP to add as an A record for custom_domain."
  value       = local.domain_enabled == 1 ? google_compute_global_address.share[0].address : null
}

# The service-account JSON key the daemon consumes as `serviceAccountKey`.
# private_key is base64-encoded JSON; decode before use.
output "service_account_key" {
  description = "gcs backend `serviceAccountKey` (JSON)."
  sensitive   = true
  value       = base64decode(google_service_account_key.client.private_key)
}
