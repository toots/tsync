# Non-secret config per store. Wire each onto the matching tsync s3 backend:
#   bucket / region / accessKeyId, and shareUrl = function_url.
output "stores" {
  description = "Per-store bucket, function_url, and access_key_id."
  value = {
    for k, m in module.store : k => {
      bucket        = m.bucket
      region        = var.region
      function_url  = m.function_url
      access_key_id = m.access_key_id
    }
  }
}

# Read one with:
#   terraform output -json secret_access_keys | jq -r '.["<store>"]'
output "secret_access_keys" {
  description = "Per-store s3 backend secretAccessKey."
  sensitive   = true
  value       = { for k, m in module.store : k => m.secret_access_key }
}
