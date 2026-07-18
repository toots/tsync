locals {
  iam_user_name = coalesce(var.iam_user_name, "tsync-client-${var.name}")
}

# ── Store bucket ───────────────────────────────────────────────────────────

resource "aws_s3_bucket" "store" {
  count  = var.create_bucket ? 1 : 0
  bucket = var.bucket
}

data "aws_s3_bucket" "store" {
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
  count      = var.create_bucket ? 1 : 0
  bucket     = local.bucket_id
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.store]
}

# ── tsync client credentials ───────────────────────────────────────────────

resource "aws_iam_user" "client" {
  name = local.iam_user_name
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
  name               = "tsync-share-${var.name}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.share.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "share" {
  # Read manifests and chunks anywhere in the store.
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/*"]
  }
  # Write only cached artifacts under the shares prefix.
  statement {
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${local.bucket_arn}/${var.shares_prefix}*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }
}

resource "aws_iam_role_policy" "share" {
  name   = "tsync-share-s3"
  role   = aws_iam_role.share.id
  policy = data.aws_iam_policy_document.share.json
}

resource "aws_lambda_function" "share" {
  function_name    = "tsync-share-${var.name}"
  role             = aws_iam_role.share.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = var.lambda_zip
  source_code_hash = var.lambda_zip_hash
  timeout          = 900
  memory_size      = var.lambda_memory_mb

  ephemeral_storage {
    size = var.ephemeral_storage_mb
  }

  environment {
    variables = {
      BUCKET        = local.bucket_id
      SHARES_PREFIX = var.shares_prefix
      PRESIGN_TTL   = tostring(var.presign_ttl)
    }
  }
}

resource "aws_lambda_function_url" "share" {
  function_name      = aws_lambda_function.share.function_name
  authorization_type = "NONE"
}

# NONE auth still needs an explicit public invoke permission or it 403s.
resource "aws_lambda_permission" "url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.share.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# ── Bucket lifecycle ───────────────────────────────────────────────────────
#
# aws_s3_bucket_lifecycle_configuration OWNS the bucket's entire lifecycle
# configuration, so this replaces any rules already on the bucket. Declare
# existing rules in extra_lifecycle_rules to keep them, or set
# manage_lifecycle = false to leave the bucket's lifecycle untouched.
resource "aws_s3_bucket_lifecycle_configuration" "shares" {
  count  = var.manage_lifecycle ? 1 : 0
  bucket = local.bucket_id

  # Expire cached share artifacts + their manifests.
  rule {
    id     = "tsync-shares-expiry"
    status = "Enabled"

    filter {
      prefix = var.shares_prefix
    }

    expiration {
      days = var.cache_expiry_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
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
