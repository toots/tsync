terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.0" }
    google  = { source = "hashicorp/google", version = ">= 5.0" }
    archive = { source = "hashicorp/archive", version = ">= 2.0" }
  }
}

locals {
  # No s3 stores — the aws provider is configured but never called. It still
  # resolves credentials eagerly when configured, so a GCS-only deploy fails on
  # "No valid credential sources found" unless the checks are switched off and
  # placeholder keys supplied. With s3 stores these are all null/false and the
  # normal credential chain applies.
  aws_unused = length(var.stores) == 0
}

provider "aws" {
  # Placeholder when unset — a GCS-only deploy configures but never calls the AWS
  # provider. s3 stores always set var.region, so this fallback is never used.
  region = coalesce(var.region, "us-east-1")

  access_key                  = local.aws_unused ? "placeholder" : null
  secret_key                  = local.aws_unused ? "placeholder" : null
  skip_credentials_validation = local.aws_unused
  skip_requesting_account_id  = local.aws_unused
  skip_metadata_api_check     = local.aws_unused
}

# Only used when var.gcs_stores is non-empty; project/region may be null for
# AWS-only deployments (the provider isn't exercised then).
provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
}

# Package the shared Lambda source once; every store reuses the same zip, and
# both functions in a store are entry points into it (handler.handler for
# shares, verify.handler for the chunk check).
#
# Excludes are exact paths, not globs, so each test file has to be named. A
# missed one ships harmlessly — nothing imports it — but it also ships its
# import of moto, so keep the list current.
data "archive_file" "handler" {
  type       = "zip"
  source_dir = "${path.module}/../lambda"
  excludes = [
    "test_handler.py",
    "test_store_gcs.py",
    "test_verify.py",
    "test_chunk_key.py",
    "test_verify_gcs.py",
    "vendor/README.md",
    "__pycache__",
    "vendor/xxhash/__pycache__",
  ]
  output_path = "${path.module}/build/lambda.zip"
}

# One store (bucket + client IAM keys + share Lambda + lifecycle) per entry in
# var.stores. Add buckets — for more domains or redundant storage — by adding map
# entries. All stores live in var.region; see README for multi-region.
module "store" {
  source   = "./modules/store-s3"
  for_each = var.stores

  name                  = each.key
  bucket                = each.value.bucket
  create_bucket         = each.value.create_bucket
  iam_user_name         = each.value.iam_user_name
  custom_domain         = each.value.custom_domain
  manage_lifecycle      = each.value.manage_lifecycle
  share_expiry_days     = each.value.share_expiry_days
  archive_after_days    = each.value.archive_after_days
  extra_lifecycle_rules = each.value.extra_lifecycle_rules
  presign_ttl           = each.value.presign_ttl
  lambda_memory_mb      = each.value.lambda_memory_mb
  ephemeral_storage_mb  = each.value.ephemeral_storage_mb

  manage_notifications   = each.value.manage_notifications
  verify_timeout_seconds = each.value.verify_timeout_seconds
  verify_memory_mb       = each.value.verify_memory_mb
  verify_max_concurrency = each.value.verify_max_concurrency

  lambda_zip      = data.archive_file.handler.output_path
  lambda_zip_hash = data.archive_file.handler.output_base64sha256
}

# ── GCS stores ─────────────────────────────────────────────────────────────
#
# Same handler zip serves both clouds (STORE env var selects the backend). A
# single bucket holds the function source for every GCS store.
resource "google_storage_bucket" "functions_source" {
  count                       = length(var.gcs_stores) > 0 ? 1 : 0
  name                        = coalesce(var.gcp_functions_source_bucket, "${var.gcp_project}-tsync-functions-src")
  location                    = var.gcp_region
  uniform_bucket_level_access = true
  force_destroy               = true
}

module "store_gcs" {
  source   = "./modules/store-gcs"
  for_each = var.gcs_stores

  name               = each.key
  bucket             = each.value.bucket
  create_bucket      = each.value.create_bucket
  location           = coalesce(each.value.location, var.gcp_region)
  function_region    = coalesce(each.value.function_region, var.gcp_function_region)
  custom_domain      = each.value.custom_domain
  manage_lifecycle   = each.value.manage_lifecycle
  share_expiry_days  = each.value.share_expiry_days
  archive_after_days = each.value.archive_after_days
  presign_ttl        = each.value.presign_ttl
  memory_mb          = each.value.memory_mb
  max_share_bytes    = each.value.max_share_bytes

  project                = var.gcp_project
  verify_timeout_seconds = each.value.verify_timeout_seconds
  verify_memory_mb       = each.value.verify_memory_mb

  source_bucket = google_storage_bucket.functions_source[0].name
  source_zip    = data.archive_file.handler.output_path
  source_hash   = data.archive_file.handler.output_base64sha256
}
