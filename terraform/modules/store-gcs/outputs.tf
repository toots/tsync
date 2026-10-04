output "bucket" {
  description = "Store bucket name (gcs backend `bucket`)."
  value       = local.bucket_name
}

# Null when the store was deployed without the share function, which is what
# tells a client this bucket serves no links.
output "share_url" {
  description = "Base URL for share links (gcs backend `shareUrl`), no trailing slash."
  value = (var.deploy_share
    ? (var.custom_domain == null
      ? trimsuffix(google_cloudfunctions2_function.share[0].url, "/")
    : "https://${var.custom_domain}")
  : null)
}

output "verify_function" {
  description = "Name of the verify function."
  value       = google_cloudfunctions2_function.verify.name
}

output "custom_domain" {
  description = "The custom domain share links are served from, or null."
  value       = local.domain_enabled == 1 ? var.custom_domain : null
}

# Records Cloud Run wants published for the mapped domain; empty when there is no
# custom_domain, and unpopulated until the mapping leaves PENDING.
output "custom_domain_dns_records" {
  description = "DNS records to publish for the custom domain (name/type/value)."
  value = local.domain_enabled == 0 ? [] : [
    for record in try(google_cloud_run_domain_mapping.share[0].status[0].resource_records, []) : {
      name  = record.name
      type  = record.type
      value = record.rrdata
    }
  ]
}

# The service-account JSON key the daemon consumes as `serviceAccountKey`.
# private_key is base64-encoded JSON; decode before use.
output "service_account_key" {
  description = "gcs backend `serviceAccountKey` (JSON)."
  sensitive   = true
  value       = base64decode(google_service_account_key.client.private_key)
}

