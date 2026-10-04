# What a conformance run needs in order to push the branch's code onto the
# function before testing it. Null for a provider that was given no bucket.
output "s3_verify_function" {
  description = "Lambda whose code a conformance run refreshes, or null."
  value       = one(module.s3[*].verify_function)
}

output "s3_region" {
  description = "Region the S3 verifier is deployed in, or null."
  value       = one(module.s3[*].region)
}

output "gcs_verify_function" {
  description = "Cloud Function whose code a conformance run refreshes, or null."
  value       = one(module.gcs[*].verify_function)
}

output "gcs_function_region" {
  description = "Region the GCS verifier is deployed in, or null."
  value       = local.gcs_unused ? null : var.gcp_function_region
}
