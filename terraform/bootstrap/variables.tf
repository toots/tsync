variable "region" {
  type        = string
  description = "AWS region for the state bucket (use the same region as your main config)."
}

variable "state_bucket" {
  type        = string
  description = "Name of the S3 bucket to create for Terraform state. Must be globally unique."
}
