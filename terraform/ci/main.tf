# The stack conformance runs against: one store named "ci" per provider, on a
# bucket scripts/setup_ci_secrets.sh already made, with no share function.
#
# A configuration and a state of its own, so that an apply here cannot reach a
# deployment's stores. The state lives beside the deployment's, in the same
# bucket under another name: the script copies the deployment's active backend
# file here and overrides the state's name at init.
#
# What it pins is the wiring, not the function's code: a conformance run pushes
# the source of the branch under test before it runs.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 6.0" }
    google  = { source = "hashicorp/google", version = ">= 5.0" }
    archive = { source = "hashicorp/archive", version = ">= 2.5" }
  }
}

locals {
  aws_unused = var.s3_bucket == null
  gcs_unused = var.gcs_bucket == null
}

provider "aws" {
  region = coalesce(var.aws_region, "us-east-1")

  access_key                  = local.aws_unused ? "placeholder" : null
  secret_key                  = local.aws_unused ? "placeholder" : null
  skip_credentials_validation = local.aws_unused
  skip_requesting_account_id  = local.aws_unused
  skip_metadata_api_check     = local.aws_unused
}

provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
}

module "package" {
  source = "../modules/package"
}

module "s3" {
  count  = local.aws_unused ? 0 : 1
  source = "../modules/store-s3"

  name = "ci"

  bucket           = var.s3_bucket
  create_bucket    = false
  manage_lifecycle = false
  deploy_share     = false

  lambda_zip      = module.package.path
  lambda_zip_hash = module.package.base64sha256
}

# Separate from a deployment's, so destroying one cannot take the other's
# source with it.
resource "google_storage_bucket" "functions_source" {
  count                       = local.gcs_unused ? 0 : 1
  name                        = "${var.gcp_project}-tsync-ci-functions-src"
  location                    = var.gcp_region
  uniform_bucket_level_access = true
  force_destroy               = true
}

resource "google_storage_bucket_object" "package" {
  count  = local.gcs_unused ? 0 : 1
  name   = "${module.package.sha256}.zip"
  bucket = google_storage_bucket.functions_source[0].name
  source = module.package.path
}

data "google_storage_project_service_account" "gcs" {
  count   = local.gcs_unused ? 0 : 1
  project = var.gcp_project
}

module "gcs" {
  count  = local.gcs_unused ? 0 : 1
  source = "../modules/store-gcs"

  name = "ci"

  bucket        = var.gcs_bucket
  create_bucket = false
  deploy_share  = false

  project         = var.gcp_project
  location        = var.gcp_region
  function_region = var.gcp_function_region

  source_bucket = google_storage_bucket.functions_source[0].name
  source_object = google_storage_bucket_object.package[0].name

  storage_agent_email = data.google_storage_project_service_account.gcs[0].email_address
}
