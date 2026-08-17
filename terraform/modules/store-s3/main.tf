locals {
  iam_user_name = coalesce(var.iam_user_name, "tsync-client-${var.name}")
  # Fixed, domain-independent shares root (matches Conf_parsing.shares_prefix in
  # the daemon). Share manifests + cached artifacts live under tsync/shares/.
  shares_prefix = "tsync/shares/"

  # A store deployed without the share function has nothing serving links and no
  # artifacts to expire; a CI stack wants the verification half alone, not a
  # public endpoint over its bucket.
  share_enabled = var.deploy_share ? 1 : 0
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
  # Write only cached artifacts under the shares prefix.
  statement {
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${local.bucket_arn}/${local.shares_prefix}*"]
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
  count            = local.share_enabled
  function_name    = "tsync-share-${var.name}"
  role             = aws_iam_role.share[0].arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = var.lambda_zip
  source_code_hash = var.lambda_zip_hash
  timeout          = 900
  memory_size      = var.lambda_memory_mb

  # Deliberately not pinned, though the zip it shares with the verify function
  # carries an aarch64 xxhash extension: nothing in handler.py imports it, so
  # the file is inert here. Pinning would force an architecture migration on
  # every existing deployment to buy nothing.

  ephemeral_storage {
    size = var.ephemeral_storage_mb
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
  count              = local.share_enabled
  function_name      = aws_lambda_function.share[0].function_name
  authorization_type = "NONE"
}

# NONE auth still needs an explicit public invoke permission or it 403s.
resource "aws_lambda_permission" "url" {
  count                  = local.share_enabled
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.share[0].function_name
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
      prefix = local.shares_prefix
    }

    expiration {
      days = var.share_expiry_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  # Opt-in cold-storage transition for ALL objects (the "glacier" ask), including
  # the shares prefix — AWS requires a transition's days be strictly less than any
  # expiration on the same object, so keep archive_after_days > share_expiry_days
  # (the operator's responsibility; not enforced here) if shares should never
  # actually reach GLACIER_IR. Off by default; the operator sets archive_after_days
  # per store.
  dynamic "rule" {
    for_each = var.archive_after_days == null ? [] : [var.archive_after_days]
    content {
      id     = "tsync-archive"
      status = "Enabled"

      filter {}

      transition {
        days          = rule.value
        storage_class = "GLACIER_IR"
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
