output "bucket" {
  description = "Store bucket name (s3 backend `bucket`)."
  value       = local.bucket_id
}

output "function_url" {
  description = "Raw share Lambda Function URL, no trailing slash."
  value       = var.deploy_share ? trimsuffix(aws_lambda_function_url.share[0].function_url, "/") : null
}

# What to wire onto the tsync s3 backend as `shareUrl`: the custom domain when
# configured, otherwise the raw Function URL.
output "share_url" {
  description = "Base URL for share links (s3 backend `shareUrl`), no trailing slash."
  value = (var.deploy_share
    ? (var.custom_domain == null
      ? trimsuffix(aws_lambda_function_url.share[0].function_url, "/")
    : "https://${var.custom_domain}")
  : null)
}

output "verify_function" {
  description = "Name of the verify function."
  value       = aws_lambda_function.verify.function_name
}

output "region" {
  description = "Region of the store (s3 backend `region`)."
  value       = aws_lambda_function.verify.region
}

output "custom_domain" {
  description = "The custom domain share links are served from, or null."
  value       = local.domain_enabled == 1 ? var.custom_domain : null
}

# The certificate's validation record first: the CNAME to the domain's target
# only exists once that one resolves.
output "custom_domain_dns_records" {
  description = "DNS records to publish for the custom domain (name/type/value)."
  value = local.domain_enabled == 0 ? [] : concat(
    [
      for option in aws_acm_certificate.share[0].domain_validation_options : {
        name  = option.resource_record_name
        type  = option.resource_record_type
        value = option.resource_record_value
      }
    ],
    [
      for target in aws_apigatewayv2_domain_name.share[*].domain_name_configuration[0].target_domain_name : {
        name  = var.custom_domain
        type  = "CNAME"
        value = target
      }
    ],
  )
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

