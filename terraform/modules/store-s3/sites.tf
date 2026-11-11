# The sites bucket of site shares (11 §7, infrastructure/aws.md §4, §7), set by
# var.sites_bucket: public reads of objects, no listing, written by the share
# function alone and served through it on the sites domain.

locals {
  sites_enabled = var.sites_bucket != null && var.sites_domain != null && var.deploy_share ? 1 : 0
}

resource "aws_s3_bucket" "sites" {
  region = var.region
  count  = local.sites_enabled
  bucket = var.sites_bucket
}

resource "aws_s3_bucket_public_access_block" "sites" {
  region                  = var.region
  count                   = local.sites_enabled
  bucket                  = aws_s3_bucket.sites[0].id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

data "aws_iam_policy_document" "sites_bucket" {
  count = local.sites_enabled

  # Objects only: nothing grants s3:ListBucket, so the tokens cannot be listed.
  statement {
    sid       = "PublicRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.sites[0].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.sites[0].arn, "${aws_s3_bucket.sites[0].arn}/*"]
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

resource "aws_s3_bucket_policy" "sites" {
  region     = var.region
  count      = local.sites_enabled
  bucket     = aws_s3_bucket.sites[0].id
  policy     = data.aws_iam_policy_document.sites_bucket[0].json
  depends_on = [aws_s3_bucket_public_access_block.sites]
}

# A published page's scripts fetch the files the function redirects them to.
resource "aws_s3_bucket_cors_configuration" "sites" {
  region = var.region
  count  = local.sites_enabled
  bucket = aws_s3_bucket.sites[0].id

  cors_rule {
    allowed_origins = ["https://${var.sites_domain}"]
    allowed_methods = ["GET", "HEAD"]
    allowed_headers = ["Range"]
    expose_headers  = ["Content-Range", "Content-Length", "Content-Type", "Accept-Ranges"]
    max_age_seconds = 3600
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "sites" {
  region = var.region
  count  = local.sites_enabled
  bucket = aws_s3_bucket.sites[0].id

  rule {
    id     = "tsync-abort-incomplete"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "site_sweep" {
  count              = local.sites_enabled
  name               = "tsync-site-sweep-${var.name}"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "site_sweep" {
  count = local.sites_enabled
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.share[0].arn]
  }
}

resource "aws_iam_role_policy" "site_sweep" {
  count  = local.sites_enabled
  name   = "tsync-site-sweep"
  role   = aws_iam_role.site_sweep[0].id
  policy = data.aws_iam_policy_document.site_sweep[0].json
}

# Invoked directly, not through the function URL: a public request never
# carries this input.
resource "aws_scheduler_schedule" "site_sweep" {
  region              = var.region
  count               = local.sites_enabled
  name                = "tsync-site-sweep-${var.name}"
  schedule_expression = "rate(1 hour)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.share[0].arn
    role_arn = aws_iam_role.site_sweep[0].arn
    input    = jsonencode({ sweep = true })
  }
}
