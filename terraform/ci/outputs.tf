# What a conformance run needs in order to push the branch's code onto the
# function before testing it. Named rather than derived, so a rename in the
# module surfaces here instead of leaving the workflow updating nothing.
output "s3_verify_function" {
  description = "Lambda whose code a conformance run refreshes, or null."
  value       = local.aws_unused ? null : "tsync-verify-ci"
}

output "gcs_verify_function" {
  description = "Cloud Function whose code a conformance run refreshes, or null."
  value       = local.gcs_unused ? null : "tsync-verify-ci"
}

output "gcs_function_region" {
  description = "Region the GCS verifier is deployed in."
  value       = local.gcs_unused ? null : var.gcp_function_region
}
