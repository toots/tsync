# The stack conformance runs against.
#
# Its own root, and its own state, because the one next door holds real stores:
# an apply here must not be able to reach them, and pointing the same
# configuration at CI buckets with different variables is exactly how it would.
# Init with the state bucket and a prefix of its own:
#
#   tofu init -backend-config=../backend.hcl -backend-config=prefix=tsync-ci
#
# It adopts the buckets scripts/setup_ci_secrets.sh already made rather than
# creating any, and deploys the verification half alone: something for the
# conformance suite to trigger, and no public endpoint over a bucket whose
# credentials live in CI.
#
# The function's *code* is not what this pins. A conformance run pushes the
# source from the branch under test before it runs, so what gets exercised is
# that branch's function rather than whatever was last applied from a laptop.

terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.0" }
    google  = { source = "hashicorp/google", version = ">= 5.0" }
    archive = { source = "hashicorp/archive", version = ">= 2.0" }
  }
  backend "gcs" {
    # bucket and prefix both supplied at init time; see above.
  }
}

locals {
  aws_unused = var.s3_bucket == null
  gcs_unused = var.gcs_bucket == null
}

provider "aws" {
  region = coalesce(var.aws_region, "us-east-1")

  # Same reasoning as the root: a configured provider resolves credentials
  # eagerly, so a GCS-only setup fails before it does anything unless the checks
  # are switched off.
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

# The same packaging the root does, from the same directory, so what CI deploys
# is built the way a real deployment is. Kept in step with ../main.tf by hand;
# a test file that ships is dead weight in the artifact rather than a fault.
data "archive_file" "handler" {
  type       = "zip"
  source_dir = "${path.module}/../../lambda"
  excludes = [
    "test_handler.py",
    "test_store_gcs.py",
    "test_verify.py",
    "test_chunk_key.py",
    "test_gc_job_key.py",
    "test_verify_gcs.py",
    "vendor/README.md",
    "__pycache__",
    "vendor/xxhash/__pycache__",
    ".pytest_cache",
    ".pytest_cache/.gitignore",
    ".pytest_cache/CACHEDIR.TAG",
    ".pytest_cache/README.md",
    ".pytest_cache/v/cache/lastfailed",
    ".pytest_cache/v/cache/nodeids",
    ".pytest_cache/v/cache/stepwise",
  ]
  output_path = "${path.module}/build/lambda.zip"
}

# Holds the function source for the GCS half, as the root's own does. Separate
# from the root's so destroying one cannot take the other's source with it.
resource "google_storage_bucket" "functions_source" {
  count                       = local.gcs_unused ? 0 : 1
  name                        = "${var.gcp_project}-tsync-ci-functions-src"
  location                    = var.gcp_region
  uniform_bucket_level_access = true
  force_destroy               = true
}

module "s3" {
  count  = local.aws_unused ? 0 : 1
  source = "../modules/store-s3"

  name = "ci"

  # Every one of these says the same thing: the bucket is the script's, not
  # this stack's. Adopt it, leave its lifecycle alone, and add only the trigger
  # and the function.
  bucket           = var.s3_bucket
  create_bucket    = false
  manage_lifecycle = false
  deploy_share     = false

  manage_notifications = true

  lambda_zip      = data.archive_file.handler.output_path
  lambda_zip_hash = data.archive_file.handler.output_base64sha256
}

module "gcs" {
  count  = local.gcs_unused ? 0 : 1
  source = "../modules/store-gcs"

  name = "ci"

  bucket           = var.gcs_bucket
  create_bucket    = false
  manage_lifecycle = false
  deploy_share     = false

  project         = var.gcp_project
  location        = var.gcp_region
  function_region = var.gcp_function_region

  source_bucket = google_storage_bucket.functions_source[0].name
  source_zip    = data.archive_file.handler.output_path
  source_hash   = data.archive_file.handler.output_base64sha256
}
