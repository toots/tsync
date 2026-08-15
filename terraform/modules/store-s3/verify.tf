# ── Chunk verification ─────────────────────────────────────────────────────
#
# A chunk's key is the hash of its bytes, so a stored chunk can be checked
# against nothing but itself. This runs on the bucket's own object-created
# event, one object per invocation, and files what fails under the domain's
# corrupted/ prefix. Clients list that prefix with the credentials they already
# have; no client ever calls this function, and no chunk body leaves the region
# to be checked.
#
# Same zip as the share function, different entry point (verify.handler).

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "verify" {
  name               = "tsync-verify-${var.name}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "verify_logs" {
  role       = aws_iam_role.verify.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "verify" {
  # Read chunks. Narrower than the share role, which reads the whole store: this
  # function has no business anywhere but the chunk namespace.
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/tsync/*/chunks/*"]
  }
  # Write and clear markers, and nothing else. A marker is cleared by the write
  # that fixed the chunk, so delete is as necessary as put.
  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.bucket_arn}/corrupted/*"]
  }
  # Sweep requests: listed to walk a shard, deleted once it is done. The client
  # writes them; this only consumes them.
  statement {
    actions   = ["s3:GetObject", "s3:DeleteObject"]
    resources = ["${local.bucket_arn}/verify-jobs/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }
}

resource "aws_iam_role_policy" "verify" {
  name   = "tsync-verify-s3"
  role   = aws_iam_role.verify.id
  policy = data.aws_iam_policy_document.verify.json
}

resource "aws_lambda_function" "verify" {
  function_name    = "tsync-verify-${var.name}"
  role             = aws_iam_role.verify.arn
  runtime          = "python3.13"
  handler          = "verify.handler"
  filename         = var.lambda_zip
  source_code_hash = var.lambda_zip_hash

  # See lambda/vendor/README.md: xxhash is a compiled extension committed for one
  # architecture, so this is not a free choice here. The share function shares
  # the zip but never imports it, and is deliberately left unpinned rather than
  # migrated (store-s3/main.tf).
  architectures = ["arm64"]

  # One chunk per invocation — 8 MiB by default — so this is a stall guard, not
  # a budget. No ephemeral storage: nothing here touches /tmp.
  timeout     = var.verify_timeout_seconds
  memory_size = var.verify_memory_mb

  # A whole-store sweep queues one request per shard, and they all become
  # deliverable at once. Unbounded, that is thousands of concurrent readers
  # against one bucket and whatever else in the account shares the account
  # concurrency pool.
  reserved_concurrent_executions = var.verify_max_concurrency

  environment {
    variables = {
      BUCKET = local.bucket_id
    }
  }
}

resource "aws_lambda_permission" "verify_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.verify.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = local.bucket_arn
  # Without this a bucket in another account could invoke it.
  source_account = data.aws_caller_identity.current.account_id
}

# ── The trigger ────────────────────────────────────────────────────────────
#
# aws_s3_bucket_notification OWNS the bucket's entire notification
# configuration, the same way aws_s3_bucket_lifecycle_configuration owns its
# lifecycle. Applying this REPLACES any notification already on the bucket —
# including one another tool put there. Set manage_notifications = false to
# leave the bucket's notifications alone, and wire verify_chunks yourself.
#
# The filter is what keeps this from recursing: markers land under
# tsync/<domain>/corrupted/, outside every prefix below, so the function's own
# writes cannot re-invoke it. verify.py's marker_key() refuses the same keys
# independently, because a filter is configuration and that is not.
resource "aws_s3_bucket_notification" "chunks" {
  count  = var.manage_notifications ? 1 : 0
  bucket = local.bucket_id

  # Every chunk written anywhere in the store. One literal prefix, no list of
  # domains to keep in step with the daemon's config — the function ignores a key
  # that is not a chunk, which it has to do anyway: a filter is configuration and
  # the code cannot lean on it.
  lambda_function {
    id                  = "tsync-verify-chunks"
    lambda_function_arn = aws_lambda_function.verify.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "tsync/"
  }

  # The other way in: `tsync chunks-integrity --verify` writes one request per
  # shard at verify-jobs/<domain>/<shard>. The domain sits inside the prefix
  # rather than around it precisely so this one rule reaches every domain.
  lambda_function {
    id                  = "tsync-verify-jobs"
    lambda_function_arn = aws_lambda_function.verify.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "verify-jobs/"
  }

  depends_on = [aws_lambda_permission.verify_s3]
}

