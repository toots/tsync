# ── Chunk verification ─────────────────────────────────────────────────────
#
# Holds each stored chunk against its own name, on the bucket's own
# object-created event, one object per invocation, filing what fails under
# tsync/corrupted/.
#
# No client calls this and no chunk body leaves the region to be checked:
# clients list that prefix with the credentials they already have.
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
    resources = ["${local.bucket_arn}/tsync/corrupted/*"]
  }
  # Sweep requests: listed to walk a shard, deleted once it is done. The client
  # writes them; this only consumes them.
  statement {
    actions   = ["s3:GetObject", "s3:DeleteObject"]
    resources = ["${local.bucket_arn}/tsync/verify-jobs/*"]
  }
  # Delete requests, the same way. Read to learn which chunks a collection
  # decided were unreferenced, deleted once every one of them is gone.
  statement {
    actions   = ["s3:GetObject", "s3:DeleteObject"]
    resources = ["${local.bucket_arn}/tsync/gc-jobs/*"]
  }
  # Drop chunks on a collection's behalf. Delete and nothing else — this reads
  # chunks above and must never write one — and scoped to the chunk namespace,
  # which is as narrow as a resource ARN goes when the domain sits in the middle
  # of the key. The request body decides which chunks, so it is validated
  # against the requesting domain in verify.py rather than trusted; this grant
  # is the ceiling on how wrong that can go.
  statement {
    actions   = ["s3:DeleteObject"]
    resources = ["${local.bucket_arn}/tsync/*/chunks/*"]
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

  # One chunk per upload event, or one gc request: its keys plus the marker each
  # could carry, so twice whatever --delete-batch was set to, in DeleteObjects
  # calls of a thousand. A stall guard rather than a budget, which is why a
  # raised --delete-batch is the operator's to keep in step with this. No
  # ephemeral storage: nothing here touches /tmp.
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
# Markers land under tsync/corrupted/, inside the prefix below, so the function's
# own writes come back to it. That terminates rather than loops: marker_key()
# returns None for a marker, so the second invocation reads nothing and writes
# nothing.
resource "aws_s3_bucket_notification" "chunks" {
  count  = var.manage_notifications ? 1 : 0
  bucket = local.bucket_id

  # One rule, because there can only be one: S3 rejects overlapping prefix
  # filters for the same event, and a chunk, a sweep request and a delete
  # request all live under tsync/. So the filter says "anything of ours" and the
  # function decides what it was handed — which it does anyway, since a filter
  # is configuration and the code cannot lean on it.
  lambda_function {
    id                  = "tsync-verify"
    lambda_function_arn = aws_lambda_function.verify.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "tsync/"
  }

  depends_on = [aws_lambda_permission.verify_s3]
}

