variable "s3_bucket" {
  type        = string
  default     = null
  description = "Existing CI bucket to attach the verifier to. Null deploys nothing on AWS."
}

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "Region the CI bucket lives in."
}

variable "gcs_bucket" {
  type        = string
  default     = null
  description = "Existing CI bucket to attach the verifier to. Null deploys nothing on GCP."
}

variable "gcp_project" {
  type        = string
  default     = null
  description = "GCP project id. Required when gcs_bucket is set."
}

variable "gcp_region" {
  type        = string
  default     = "us-central1"
  description = "Region for the source bucket."
}

variable "gcp_function_region" {
  type        = string
  default     = "us-central1"
  description = "Region for the verifier. Must be a specific region, not a multi-region."
}
