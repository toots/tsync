variable "project" {
  type        = string
  description = "GCP project id for the state bucket."
}

variable "location" {
  type        = string
  description = "Location for the state bucket (e.g. US, us-central1). Use the same location as your main config."
}

variable "state_bucket" {
  type        = string
  description = "Name of the GCS bucket to create for Terraform state. Must be globally unique."
}
