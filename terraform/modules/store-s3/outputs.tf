output "bucket" {
  description = "Store bucket name (s3 backend `bucket`)."
  value       = local.bucket_id
}

output "function_url" {
  description = "Raw share Lambda Function URL, no trailing slash."
  value       = trimsuffix(aws_lambda_function_url.share.function_url, "/")
}

# What to wire onto the tsync s3 backend as `shareUrl`: the custom domain when
# configured, otherwise the raw Function URL.
output "share_url" {
  description = "Base URL for share links (s3 backend `shareUrl`), no trailing slash."
  value       = var.custom_domain == null ? trimsuffix(aws_lambda_function_url.share.function_url, "/") : "https://${var.custom_domain}"
}

# Add this CNAME at your DNS provider so ACM can issue the cert.
output "acm_validation_records" {
  description = "CNAME record(s) to add for ACM DNS validation (empty when no custom_domain)."
  value = var.custom_domain == null ? [] : [
    for o in aws_acm_certificate.share[0].domain_validation_options : {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  ]
}

# Then CNAME custom_domain -> this. null until the domain resource exists (i.e.
# after the cert validates and the full apply runs). try() keeps it null-safe
# during the cert-only targeted apply, so it never breaks custom_domain_dns.
output "custom_domain_target" {
  description = "CNAME target for the custom domain (null until the full apply completes)."
  value       = try(aws_apigatewayv2_domain_name.share[0].domain_name_configuration[0].target_domain_name, null)
}

# Signals whether this store has a custom domain configured, so the root
# custom_domain_dns output can list it as soon as the cert exists.
output "custom_domain" {
  description = "The configured custom domain, or null."
  value       = var.custom_domain
}

output "access_key_id" {
  description = "s3 backend `accessKeyId`."
  value       = aws_iam_access_key.client.id
}

output "secret_access_key" {
  description = "s3 backend `secretAccessKey`."
  value       = aws_iam_access_key.client.secret
  sensitive   = true
}
