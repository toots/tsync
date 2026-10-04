terraform {
  required_version = ">= 1.10"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 6.0" }
    google  = { source = "hashicorp/google", version = ">= 5.0" }
    archive = { source = "hashicorp/archive", version = ">= 2.5" }
  }
}

locals {
  # A configured aws provider resolves credentials even when nothing calls it,
  # so a deployment with no s3 store switches the checks off and supplies
  # placeholder keys.
  aws_unused = length(var.stores) == 0
  gcs_used   = length(var.gcs_stores) > 0

  duplicate_names = setintersection(keys(var.stores), keys(var.gcs_stores))
}

provider "aws" {
  region = coalesce(var.region, "us-east-1")

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

# A store name keys the outputs whatever its provider, so it has to be unique
# across both maps.
resource "terraform_data" "store_names" {
  lifecycle {
    precondition {
      condition     = length(local.duplicate_names) == 0
      error_message = "Store names must be unique across stores and gcs_stores: ${join(", ", local.duplicate_names)}."
    }
  }
}

module "package" {
  source = "./modules/package"
}

module "store" {
  source   = "./modules/store-s3"
  for_each = var.stores

  name                  = each.key
  bucket                = each.value.bucket
  create_bucket         = each.value.create_bucket
  region                = each.value.region
  iam_user_name         = each.value.iam_user_name
  deploy_share          = each.value.share
  custom_domain         = each.value.custom_domain
  manage_lifecycle      = each.value.manage_lifecycle
  archive_domains       = each.value.archive_domains
  extra_lifecycle_rules = each.value.extra_lifecycle_rules
  presign_ttl           = each.value.presign_ttl
  max_share_bytes       = each.value.max_share_bytes
  share_memory_mb       = each.value.share_memory_mb
  share_scratch_mb      = each.value.share_scratch_mb

  manage_notifications   = each.value.manage_notifications
  verify_timeout_seconds = each.value.verify_timeout_seconds
  verify_memory_mb       = each.value.verify_memory_mb
  verify_max_concurrency = each.value.verify_max_concurrency

  lambda_zip      = module.package.path
  lambda_zip_hash = module.package.base64sha256
}

# Switched on, and left on when the deployment is destroyed: another stack in
# the project may be using them.
resource "google_project_service" "required" {
  for_each = local.gcs_used ? toset([
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
    "eventarc.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
  ]) : toset([])

  project            = var.gcp_project
  service            = each.key
  disable_on_destroy = false
}

resource "google_storage_bucket" "functions_source" {
  count                       = local.gcs_used ? 1 : 0
  name                        = coalesce(var.gcp_functions_source_bucket, "${var.gcp_project}-tsync-functions-src")
  location                    = var.gcp_region
  uniform_bucket_level_access = true
  force_destroy               = true

  depends_on = [google_project_service.required]
}

# Named by its hash, so a new package is a new object and every function built
# from it is redeployed.
resource "google_storage_bucket_object" "package" {
  count  = local.gcs_used ? 1 : 0
  name   = "${module.package.sha256}.zip"
  bucket = google_storage_bucket.functions_source[0].name
  source = module.package.path
}

module "store_gcs" {
  source   = "./modules/store-gcs"
  for_each = var.gcs_stores

  name            = each.key
  bucket          = each.value.bucket
  create_bucket   = each.value.create_bucket
  location        = coalesce(each.value.location, var.gcp_region)
  function_region = coalesce(each.value.function_region, var.gcp_function_region)
  deploy_share    = each.value.share
  custom_domain   = each.value.custom_domain
  archive_domains = each.value.archive_domains
  presign_ttl     = each.value.presign_ttl
  max_share_bytes = each.value.max_share_bytes
  share_memory_mb = each.value.share_memory_mb

  project                = var.gcp_project
  verify_timeout_seconds = each.value.verify_timeout_seconds
  verify_memory_mb       = each.value.verify_memory_mb
  verify_max_concurrency = each.value.verify_max_concurrency

  source_bucket = google_storage_bucket.functions_source[0].name
  source_object = google_storage_bucket_object.package[0].name

  depends_on = [google_project_service.required]
}
