# Non-secret config per store. Wire each onto the matching tsync s3 backend:
#   bucket / region / accessKeyId, and shareUrl = share_url.
output "stores" {
  description = "Per-store bucket, share_url, and access_key_id."
  value = {
    for k, m in module.store : k => {
      bucket        = m.bucket
      region        = var.region
      share_url     = m.share_url
      access_key_id = m.access_key_id
    }
  }
}

# DNS records to add at your provider for stores with a custom_domain. Only
# populated for those stores; empty otherwise.
output "custom_domain_dns" {
  description = "Per-store DNS records to create for the custom domain (ACM validation + the domain CNAME target)."
  value = {
    for k, m in module.store : k => {
      acm_validation = m.acm_validation_records
      cname_target   = m.custom_domain_target
    } if m.custom_domain != null
  }
}

# Read one with:
#   terraform output -json secret_access_keys | jq -r '.["<store>"]'
output "secret_access_keys" {
  description = "Per-store s3 backend secretAccessKey."
  sensitive   = true
  value       = { for k, m in module.store : k => m.secret_access_key }
}

# ── GCS stores ─────────────────────────────────────────────────────────────
# Wire each onto the matching tsync gcs backend: bucket / shareUrl.
output "gcs_stores" {
  description = "Per-GCS-store bucket and share_url."
  value = {
    for k, m in module.store_gcs : k => {
      bucket    = m.bucket
      share_url = m.share_url
    }
  }
}

# The gcs backend `serviceAccountKey` (JSON) per store. Read one with:
#   terraform output -json gcs_service_account_keys | jq -r '.["<store>"]'
output "gcs_service_account_keys" {
  description = "Per-GCS-store gcs backend serviceAccountKey (JSON)."
  sensitive   = true
  value       = { for k, m in module.store_gcs : k => m.service_account_key }
}

# A record to add per GCS store with a custom_domain: point the domain at a_record.
# Only populated for those stores; empty otherwise.
output "gcs_custom_domain_dns" {
  description = "Per-GCS-store A record for the custom domain (domain -> load balancer IP)."
  value = {
    for k, m in module.store_gcs : k => { domain = m.custom_domain, a_record = m.custom_domain_ip }
    if m.custom_domain != null
  }
}
