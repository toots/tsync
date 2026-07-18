terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.0" }
    archive = { source = "hashicorp/archive", version = ">= 2.0" }
  }
}

provider "aws" {
  region = var.region
}

# Package the shared Lambda handler once; every store reuses the same zip.
data "archive_file" "handler" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/build/lambda.zip"
}

# One store (bucket + client IAM keys + share Lambda + lifecycle) per entry in
# var.stores. Add buckets — for more domains or redundant storage — by adding map
# entries. All stores live in var.region; see README for multi-region.
module "store" {
  source   = "./modules/store"
  for_each = var.stores

  name                  = each.key
  bucket                = each.value.bucket
  create_bucket         = each.value.create_bucket
  iam_user_name         = each.value.iam_user_name
  shares_prefix         = each.value.shares_prefix
  manage_lifecycle      = each.value.manage_lifecycle
  cache_expiry_days     = each.value.cache_expiry_days
  extra_lifecycle_rules = each.value.extra_lifecycle_rules
  presign_ttl           = each.value.presign_ttl
  lambda_memory_mb      = each.value.lambda_memory_mb
  ephemeral_storage_mb  = each.value.ephemeral_storage_mb

  lambda_zip      = data.archive_file.handler.output_path
  lambda_zip_hash = data.archive_file.handler.output_base64sha256
}
