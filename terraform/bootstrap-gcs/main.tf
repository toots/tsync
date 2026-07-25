# Bootstrap: creates the GCS bucket that holds the Terraform state for the main
# config. Chicken-and-egg — this can't itself use the gcs backend, so it keeps
# its state locally (bootstrap-gcs/terraform.tfstate). Run once:
#
#   cd bootstrap-gcs
#   terraform init
#   terraform apply -var project=my-gcp-project -var location=US -var state_bucket=my-tsync-tfstate
#
# Losing the local bootstrap state is harmless: the bucket still exists, and the
# main config's state lives inside it, versioned.

terraform {
  required_version = ">= 1.10"
  required_providers {
    google = { source = "hashicorp/google", version = ">= 5.0" }
  }
}

provider "google" {
  project = var.project
  region  = var.location
}

resource "google_storage_bucket" "state" {
  name                        = var.state_bucket
  location                    = var.location
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  # Keep old state versions from piling up forever.
  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 90
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = 1
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }
}
