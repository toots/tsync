terraform {
  required_providers {
    google = { source = "hashicorp/google", version = ">= 5.0" }
  }
}

# ── Store bucket ───────────────────────────────────────────────────────────
#
# Lifecycle is part of the bucket itself, so it is managed on a bucket this
# store created and never on an adopted one.

resource "google_storage_bucket" "store" {
  count                       = var.create_bucket ? 1 : 0
  name                        = var.bucket
  location                    = var.location
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition { age = 1 }
    action { type = "AbortIncompleteMultipartUpload" }
  }

  # One rule per archived domain, over that domain's chunks and nothing else. A
  # chunk is "tsync/<domain>/chunks/<shard>/<key>" — the domain sits in the
  # middle, so no wildcard spans domains and a domain nobody named never
  # archives. matches_prefix takes a list, but each domain carries its own age,
  # so they cannot be collapsed into one rule. Everything outside these prefixes
  # stays STANDARD: manifests, versions, the journal and the cursor are read on
  # every sync, and shares are the application's to expire.
  dynamic "lifecycle_rule" {
    for_each = var.archive_domains
    content {
      condition {
        age            = lifecycle_rule.value.after_days
        matches_prefix = ["tsync/${lifecycle_rule.key}/chunks/"]
      }
      action {
        type          = "SetStorageClass"
        storage_class = coalesce(lifecycle_rule.value.storage_class, "ARCHIVE")
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
  # The share function's whole write scope: assembled artifacts and the
  # temporary objects that build them, never a share manifest, which sits one
  # level up at tsync/shares/<token>.
  share_cache_prefix = "tsync/shares/cache/"

  # A store deployed without the share function has nothing serving links and
  # nothing writing cached artifacts; a CI stack wants the verification half
  # alone, not a public endpoint over its bucket.
  share_enabled = var.deploy_share ? 1 : 0
}

# ── tsync client credentials ───────────────────────────────────────────────

resource "google_service_account" "client" {
  account_id   = "tsync-client-${var.name}"
  display_name = "tsync client ${var.name}"

  # Checked here because this is the one resource every store has: a refusal
  # stops the plan whatever else the store was asked for.
  lifecycle {
    precondition {
      condition     = var.custom_domain == null || var.deploy_share
      error_message = "Store ${var.name}: custom_domain needs the share function (share = true)."
    }
    precondition {
      condition     = var.max_share_bytes <= (var.share_memory_mb - 512) * 1024 * 1024
      error_message = "Store ${var.name}: max_share_bytes must leave 512 MB of share_memory_mb free, since a folder archive is built in memory. Raise the two together."
    }
    precondition {
      condition     = var.create_bucket || length(var.archive_domains) == 0
      error_message = "Store ${var.name}: archive_domains needs a bucket this store creates; an adopted bucket's lifecycle is yours."
    }
  }
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
  count        = local.share_enabled
  account_id   = "tsync-share-${var.name}"
  display_name = "tsync share ${var.name}"
}

# Read manifests + chunks anywhere in the store (this also grants object list,
# which an IAM Condition can't scope by prefix).
resource "google_storage_bucket_iam_member" "share_read" {
  count  = local.share_enabled
  bucket = local.bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.share[0].email}"
}

# Write, and delete the temporary objects compose goes through, under the share
# cache only. A bucket grant is scoped to a prefix by a condition.
resource "google_storage_bucket_iam_member" "share_write" {
  count  = local.share_enabled
  bucket = local.bucket_name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.share[0].email}"
  condition {
    title      = "share-cache-only"
    expression = "resource.name.startsWith(\"projects/_/buckets/${local.bucket_name}/objects/${local.share_cache_prefix}\")"
  }
}

# Sign V4 URLs from inside the function (no raw private key at runtime): the SA
# must be able to call the IAM SignBlob API on itself.
resource "google_service_account_iam_member" "share_signer" {
  count              = local.share_enabled
  service_account_id = google_service_account.share[0].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.share[0].email}"
}

resource "google_cloudfunctions2_function" "share" {
  count    = local.share_enabled
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
        object = var.source_object
      }
    }
  }

  service_config {
    available_memory      = "${var.share_memory_mb}M"
    timeout_seconds       = var.timeout_seconds
    service_account_email = google_service_account.share[0].email
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
  count    = local.share_enabled
  location = google_cloudfunctions2_function.share[0].location
  name     = google_cloudfunctions2_function.share[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
