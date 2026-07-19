output "bucket" {
  description = "Store bucket name (s3 backend `bucket`)."
  value       = local.bucket_id
}

output "function_url" {
  description = "Share Lambda URL (s3 backend `shareUrl`), no trailing slash."
  value       = trimsuffix(aws_lambda_function_url.share.function_url, "/")
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
