# One GCS store: bucket + client service-account key + share Cloud Function +
# lifecycle. Mirrors modules/store (the AWS variant) on the google provider.

# ── Store bucket ───────────────────────────────────────────────────────────
#
# GCS lifecycle is a property of the bucket resource (no separate resource), so
# it can only be managed on a bucket we create. A pre-existing bucket is read
# via a data source and left untouched.

resource "google_storage_bucket" "store" {
  count                       = var.create_bucket ? 1 : 0
  name                        = var.bucket
  location                    = var.location
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Expire cached share artifacts + their manifests.
  dynamic "lifecycle_rule" {
    for_each = var.manage_lifecycle ? [1] : []
    content {
      condition {
        age            = var.share_expiry_days
        matches_prefix = [local.shares_prefix]
      }
      action { type = "Delete" }
    }
  }

  # Abort dangling resumable uploads.
  dynamic "lifecycle_rule" {
    for_each = var.manage_lifecycle ? [1] : []
    content {
      condition { age = 1 }
      action { type = "AbortIncompleteMultipartUpload" }
    }
  }

  # Opt-in cold-storage transition for ALL objects (the "glacier" ask), including
  # the shares prefix — GCS applies Delete over SetStorageClass at equal age, so
  # keep archive_after_days > share_expiry_days (the operator's responsibility;
  # not enforced here) if shares should never actually reach ARCHIVE. Off by
  # default; the operator sets archive_after_days per store.
  dynamic "lifecycle_rule" {
    for_each = var.archive_after_days == null ? [] : [var.archive_after_days]
    content {
      condition { age = lifecycle_rule.value }
      action {
        type          = "SetStorageClass"
        storage_class = "ARCHIVE"
      }
    }
  }
}

data "google_storage_bucket" "store" {
  count = var.create_bucket ? 0 : 1
  name  = var.bucket
}

locals {
  bucket_name = var.create_bucket ? google_storage_bucket.store[0].name : data.google_storage_bucket.store[0].name
  # Fixed, domain-independent shares root (matches Conf_parsing.shares_prefix in
  # the daemon). Share manifests + cached artifacts live under tsync/shares/.
  shares_prefix = "tsync/shares/"
}

# ── tsync client credentials ───────────────────────────────────────────────

resource "google_service_account" "client" {
  account_id   = "tsync-client-${var.name}"
  display_name = "tsync client ${var.name}"
}

# The daemon mints its token with the devstorage.full_control scope, because the
# XML API's bulk delete — which is how `tsync gc` removes chunks, a thousand keys
# to the request — rejects a read_write token. That is a ceiling on the token,
# not a grant: this role is what the account may actually do, and it stays
# objects-only. Widening it to roles/storage.admin would be the thing to avoid.
resource "google_storage_bucket_iam_member" "client" {
  bucket = local.bucket_name
  role   = "roles/storage.objectUser" # get/create/delete/list objects
  member = "serviceAccount:${google_service_account.client.email}"
}

# The JSON key the daemon consumes as `serviceAccountKey`.
resource "google_service_account_key" "client" {
  service_account_id = google_service_account.client.name
}

# ── Share Cloud Function (gen2) ────────────────────────────────────────────

resource "google_service_account" "share" {
  account_id   = "tsync-share-${var.name}"
  display_name = "tsync share ${var.name}"
}

# Read manifests + chunks anywhere in the store (this also grants object list,
# which an IAM Condition can't scope by prefix).
resource "google_storage_bucket_iam_member" "share_read" {
  bucket = local.bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.share.email}"
}

# Write (and delete temp compose objects) only under the shares prefix. GCS IAM
# is bucket-granular, so the prefix scope is expressed as an IAM Condition.
resource "google_storage_bucket_iam_member" "share_write" {
  bucket = local.bucket_name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.share.email}"
  condition {
    title      = "shares-prefix-only"
    expression = "resource.name.startsWith(\"projects/_/buckets/${local.bucket_name}/objects/${local.shares_prefix}\")"
  }
}

# Sign V4 URLs from inside the function (no raw private key at runtime): the SA
# must be able to call the IAM SignBlob API on itself.
resource "google_service_account_iam_member" "share_signer" {
  service_account_id = google_service_account.share.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.share.email}"
}

resource "google_storage_bucket_object" "source" {
  name   = "tsync-share-${var.name}/${var.source_hash}.zip"
  bucket = var.source_bucket
  source = var.source_zip
}

resource "google_cloudfunctions2_function" "share" {
  name     = "tsync-share-${var.name}"
  location = var.function_region

  build_config {
    runtime     = "python313"
    entry_point = "gcp_handler"
    # The Python buildpack defaults to main.py; our entry point lives in
    # handler.py (shared with the AWS Lambda), so point the buildpack at it.
    environment_variables = {
      GOOGLE_FUNCTION_SOURCE = "handler.py"
    }
    source {
      storage_source {
        bucket = var.source_bucket
        object = google_storage_bucket_object.source.name
      }
    }
  }

  service_config {
    available_memory      = "${var.memory_mb}M"
    timeout_seconds       = var.timeout_seconds
    service_account_email = google_service_account.share.email
    environment_variables = {
      BUCKET      = local.bucket_name
      PRESIGN_TTL = tostring(var.presign_ttl)
      MAX_BYTES   = tostring(var.max_share_bytes)
      STORE       = "gcs"
    }
  }
}

# Public, unauthenticated access — the GCP equal of the Lambda function-URL NONE
# auth. A gen2 function is backed by a Cloud Run service of the same name.
resource "google_cloud_run_v2_service_iam_member" "public" {
  location = google_cloudfunctions2_function.share.location
  name     = google_cloudfunctions2_function.share.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
