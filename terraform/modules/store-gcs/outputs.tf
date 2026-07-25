output "bucket" {
  description = "Store bucket name (gcs backend `bucket`)."
  value       = local.bucket_name
}

output "share_url" {
  description = "Base URL for share links (gcs backend `shareUrl`), no trailing slash."
  value       = trimsuffix(google_cloudfunctions2_function.share.url, "/")
}

# The service-account JSON key the daemon consumes as `serviceAccountKey`.
# private_key is base64-encoded JSON; decode before use.
output "service_account_key" {
  description = "gcs backend `serviceAccountKey` (JSON)."
  sensitive   = true
  value       = base64decode(google_service_account_key.client.private_key)
}
