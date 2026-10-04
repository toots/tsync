terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
}

locals {
  iam_user_name = coalesce(var.iam_user_name, "tsync-client-${var.name}")
  # The share function's whole write scope: assembled artifacts, never a share
  # manifest, which sits one level up at tsync/shares/<token>.
  share_cache_prefix = "tsync/shares/cache/"

  # Storage classes a chunk can be read from with no restore step.
  online_classes = ["STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING", "GLACIER_IR"]

  # Operator rules whose filter can match a key under tsync/.
  rules_under_tsync = [
    for rule in var.extra_lifecycle_rules : rule
    if startswith("tsync/", rule.prefix) || startswith(rule.prefix, "tsync/")
  ]

  # A store deployed without the share function has nothing serving links and
  # nothing writing cached artifacts; a CI stack wants the verification half
  # alone, not a public endpoint over its bucket.
  share_enabled = var.deploy_share ? 1 : 0
}

# ── Store bucket ───────────────────────────────────────────────────────────

resource "aws_s3_bucket" "store" {
  region = var.region
  count  = var.create_bucket ? 1 : 0
  bucket = var.bucket
}

data "aws_s3_bucket" "store" {
  region = var.region
  count  = var.create_bucket ? 0 : 1
  bucket = var.bucket
}

locals {
  bucket_id  = var.create_bucket ? aws_s3_bucket.store[0].id : data.aws_s3_bucket.store[0].id
  bucket_arn = var.create_bucket ? aws_s3_bucket.store[0].arn : data.aws_s3_bucket.store[0].arn
}

# Lock a freshly created bucket down: no public access, TLS-only. Skipped for a
# pre-existing bucket so we don't clobber its existing access settings.
resource "aws_s3_bucket_public_access_block" "store" {
  region                  = var.region
  count                   = var.create_bucket ? 1 : 0
  bucket                  = local.bucket_id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "store" {
  region     = var.region
  count      = var.create_bucket ? 1 : 0
  bucket     = local.bucket_id
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.store]
}

# ── tsync client credentials ───────────────────────────────────────────────

resource "aws_iam_user" "client" {
  name = local.iam_user_name

  # Checked here because this is the one resource every store has: a refusal
  # stops the plan whatever else the store was asked for.
  lifecycle {
    precondition {
      condition     = var.custom_domain == null || var.deploy_share
      error_message = "Store ${var.name}: custom_domain needs the share function (share = true)."
    }
    precondition {
      condition     = var.max_share_bytes <= (var.share_scratch_mb - 1024) * 1024 * 1024
      error_message = "Store ${var.name}: max_share_bytes must leave 1 GiB of share_scratch_mb free, since a folder archive is built there."
    }
    precondition {
      condition = alltrue([
        for rule in local.rules_under_tsync : rule.expiration_days == null && alltrue([
          for transition in rule.transitions : contains(local.online_classes, transition.storage_class)
        ])
      ])
      error_message = "Store ${var.name}: an extra lifecycle rule that can match under tsync/ must not expire anything, and may transition only to ${join(", ", local.online_classes)}."
    }
    precondition {
      condition = alltrue([
        for rule in var.extra_lifecycle_rules :
        rule.id != "tsync-abort-incomplete" && !startswith(rule.id, "tsync-archive-")
      ])
      error_message = "Store ${var.name}: extra lifecycle rule ids must differ from the store's own (tsync-abort-incomplete, tsync-archive-<domain>)."
    }
  }
}

data "aws_iam_policy_document" "client" {
  statement {
    sid       = "List"
    actions   = ["s3:ListBucket", "s3:ListBucketMultipartUploads"]
    resources = [local.bucket_arn]
  }
  statement {
    sid = "Objects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${local.bucket_arn}/*"]
  }
}

resource "aws_iam_user_policy" "client" {
  name   = "tsync-store-access"
  user   = aws_iam_user.client.name
  policy = data.aws_iam_policy_document.client.json
}

resource "aws_iam_access_key" "client" {
  user = aws_iam_user.client.name
}

# ── Share Lambda + public Function URL ─────────────────────────────────────

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "share" {
  count              = local.share_enabled
  name               = "tsync-share-${var.name}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "logs" {
  count      = local.share_enabled
  role       = aws_iam_role.share[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "share" {
  # Read manifests and chunks anywhere in the store.
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/*"]
  }
  statement {
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${local.bucket_arn}/${local.share_cache_prefix}*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }
}

resource "aws_iam_role_policy" "share" {
  count  = local.share_enabled
  name   = "tsync-share-s3"
  role   = aws_iam_role.share[0].id
  policy = data.aws_iam_policy_document.share.json
}

resource "aws_lambda_function" "share" {
  region           = var.region
  count            = local.share_enabled
  function_name    = "tsync-share-${var.name}"
  role             = aws_iam_role.share[0].arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = var.lambda_zip
  source_code_hash = var.lambda_zip_hash
  timeout          = 900
  memory_size      = var.share_memory_mb

  # Deliberately not pinned, though the zip it shares with the verify function
  # carries an aarch64 xxhash extension: nothing in handler.py imports it, so
  # the file is inert here. Pinning would force an architecture migration on
  # every existing deployment to buy nothing.

  ephemeral_storage {
    size = var.share_scratch_mb
  }

  environment {
    variables = {
      BUCKET      = local.bucket_id
      PRESIGN_TTL = tostring(var.presign_ttl)
      MAX_BYTES   = tostring(var.max_share_bytes)
    }
  }
}

resource "aws_lambda_function_url" "share" {
  region             = var.region
  count              = local.share_enabled
  function_name      = aws_lambda_function.share[0].function_name
  authorization_type = "NONE"
}

# A public function URL answers 403 unless both permissions are granted.
resource "aws_lambda_permission" "url" {
  region                 = var.region
  count                  = local.share_enabled
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.share[0].function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "url_invoke" {
  region                   = var.region
  count                    = local.share_enabled
  statement_id             = "AllowPublicFunctionUrlInvoke"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.share[0].function_name
  principal                = "*"
  invoked_via_function_url = true
}

# ── Bucket lifecycle ───────────────────────────────────────────────────────
#
# aws_s3_bucket_lifecycle_configuration OWNS the bucket's entire lifecycle
# configuration, so this replaces any rules already on the bucket. Declare
# existing rules in extra_lifecycle_rules to keep them, or set
# manage_lifecycle = false to leave the bucket's lifecycle untouched.

moved {
  from = aws_s3_bucket_lifecycle_configuration.shares
  to   = aws_s3_bucket_lifecycle_configuration.store
}

resource "aws_s3_bucket_lifecycle_configuration" "store" {
  region = var.region
  count  = var.manage_lifecycle ? 1 : 0
  bucket = local.bucket_id

  # Abort dangling multipart uploads anywhere in the bucket — a chunk write that
  # died mid-flight bills for its parts until something reaps them. Unconditional,
  # which is also what keeps the configuration from ever being empty: S3 rejects
  # one with no rules, and every other rule here is opt-in.
  rule {
    id     = "tsync-abort-incomplete"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  # One rule per archived domain, over that domain's chunks and nothing else. A
  # chunk is "tsync/<domain>/chunks/<shard>/<key>" — the domain sits in the
  # middle, and a rule filter holds one literal prefix, so each domain needs its
  # own rule and a domain nobody named never archives. Everything outside these
  # prefixes stays in STANDARD: manifests, versions, the journal and the cursor
  # are read on every sync, and shares are the application's to expire.
  dynamic "rule" {
    for_each = var.archive_domains
    content {
      id     = "tsync-archive-${rule.key}"
      status = "Enabled"

      filter {
        prefix = "tsync/${rule.key}/chunks/"
      }

      transition {
        days          = rule.value.after_days
        storage_class = coalesce(rule.value.storage_class, "GLACIER_IR")
      }
    }
  }

  # Your own rules, preserved.
  dynamic "rule" {
    for_each = var.extra_lifecycle_rules
    content {
      id     = rule.value.id
      status = "Enabled"

      filter {
        prefix = rule.value.prefix
      }

      dynamic "transition" {
        for_each = rule.value.transitions
        content {
          days          = transition.value.days
          storage_class = transition.value.storage_class
        }
      }

      dynamic "expiration" {
        for_each = rule.value.expiration_days == null ? [] : [rule.value.expiration_days]
        content {
          days = expiration.value
        }
      }
    }
  }
}
