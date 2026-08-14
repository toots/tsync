# ── Chunk verification ─────────────────────────────────────────────────────
#
# Mirrors modules/store-s3/verify.tf on the google provider. A chunk's key is
# the hash of its bytes, so a stored chunk can be checked against nothing but
# itself; this runs on the bucket's own object-created event, one object per
# invocation, and files what fails under the domain's corrupted/ prefix.
#
# Same source zip as the share function, different entry point (gcp_verify).
#
# Delivery is a storage notification onto Pub/Sub, NOT an Eventarc storage
# trigger. Eventarc's google.cloud.storage.object.v1.finalized has no prefix
# filter, so it would invoke this on every manifest, journal entry and share
# artifact written to the bucket — and, since the function writes markers into
# the bucket it watches, on its own writes as well. object_name_prefix is what
# makes the trigger match only chunks.

locals {
  # As on the AWS side: no safe default. A prefix matching nothing deploys a
  # function that never fires, which is indistinguishable from a clean store.
  verify_enabled = length(var.chunk_domains) > 0
}

resource "google_service_account" "verify" {
  count        = local.verify_enabled ? 1 : 0
  account_id   = "tsync-verify-${var.name}"
  display_name = "tsync verify ${var.name}"
}

# Read. The same bucket-wide grant the share SA gets, NOT narrowed to the chunk
# namespace the way the AWS policy is (store-s3/verify.tf) — objectViewer
# carries objects.list, which an IAM Condition cannot scope by prefix, and
# splitting it into a conditioned objectUser would fail silently: a verifier that
# cannot read reports no markers, which is indistinguishable from a clean store.
# Narrow it once there is a real bucket to confirm the grant against.
resource "google_storage_bucket_iam_member" "verify_read" {
  count  = local.verify_enabled ? 1 : 0
  bucket = local.bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.verify[0].email}"
}

# Write and clear markers, and nothing else. Delete matters as much as write: a
# marker is cleared by the very write that fixed the chunk.
resource "google_storage_bucket_iam_member" "verify_mark" {
  count  = local.verify_enabled ? 1 : 0
  bucket = local.bucket_name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.verify[0].email}"
  condition {
    title = "corrupted-prefix-only"
    # One condition covering every domain in this bucket: IAM conditions do not
    # take a list, and a binding per domain would collide on the title.
    # Markers to file, and sweep requests to consume once their shard is done.
    expression = join(" || ", flatten([
      for d in var.chunk_domains : [
        "resource.name.startsWith(\"projects/_/buckets/${local.bucket_name}/objects/tsync/${d}/corrupted/\")",
        "resource.name.startsWith(\"projects/_/buckets/${local.bucket_name}/objects/tsync/${d}/verify-jobs/\")",
      ]
    ]))
  }
}

# ── The trigger ────────────────────────────────────────────────────────────

resource "google_pubsub_topic" "chunks" {
  count = local.verify_enabled ? 1 : 0
  name  = "tsync-chunks-${var.name}"
}

# Cloud Storage publishes as its own per-project service agent, which has no
# rights on a new topic until granted them.
data "google_storage_project_service_account" "gcs" {
  count = local.verify_enabled ? 1 : 0
}

resource "google_pubsub_topic_iam_member" "gcs_publisher" {
  count  = local.verify_enabled ? 1 : 0
  topic  = google_pubsub_topic.chunks[0].id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${data.google_storage_project_service_account.gcs[0].email_address}"
}

resource "google_storage_notification" "chunks" {
  for_each           = local.verify_enabled ? toset(var.chunk_domains) : toset([])
  bucket             = local.bucket_name
  topic              = google_pubsub_topic.chunks[0].id
  payload_format     = "JSON_API_V1"
  event_types        = ["OBJECT_FINALIZE"]
  object_name_prefix = "tsync/${each.key}/chunks/"

  # The binding must exist first or the notification is rejected.
  depends_on = [google_pubsub_topic_iam_member.gcs_publisher]
}

# The other way in: `tsync chunks-integrity --verify` writes one request per
# shard here, and this delivers them to the same function. Its own notification
# rather than a wider prefix, so a marker still cannot trigger anything.
resource "google_storage_notification" "verify_jobs" {
  for_each           = local.verify_enabled ? toset(var.chunk_domains) : toset([])
  bucket             = local.bucket_name
  topic              = google_pubsub_topic.chunks[0].id
  payload_format     = "JSON_API_V1"
  event_types        = ["OBJECT_FINALIZE"]
  object_name_prefix = "tsync/${each.key}/verify-jobs/"

  depends_on = [google_pubsub_topic_iam_member.gcs_publisher]
}

# The only resource here that needs the project spelled out; the rest take it
# from the provider.
resource "google_project_iam_member" "verify_receiver" {
  count   = local.verify_enabled ? 1 : 0
  project = var.project
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.verify[0].email}"
}

resource "google_cloudfunctions2_function" "verify" {
  count    = local.verify_enabled ? 1 : 0
  name     = "tsync-verify-${var.name}"
  location = var.function_region

  build_config {
    runtime     = "python313"
    entry_point = "gcp_verify"
    # The buildpack defaults to main.py; ours is verify.py. xxhash comes from
    # requirements.txt here — the vendored wheel is for Lambda, and verify.py
    # appends rather than prepends vendor/ so this copy wins.
    environment_variables = {
      GOOGLE_FUNCTION_SOURCE = "verify.py"
    }
    source {
      storage_source {
        bucket = var.source_bucket
        object = google_storage_bucket_object.source.name
      }
    }
  }

  service_config {
    available_memory      = "${var.verify_memory_mb}M"
    timeout_seconds       = var.verify_timeout_seconds
    service_account_email = google_service_account.verify[0].email
    environment_variables = {
      BUCKET = local.bucket_name
      STORE  = "gcs"
    }
  }

  event_trigger {
    trigger_region = var.function_region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.chunks[0].id
    # A bucket the function cannot read would otherwise retry against every
    # chunk in it, forever. A dropped event costs a missed marker, which is
    # exactly what the store looked like before any of this existed.
    retry_policy          = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.verify[0].email
  }
}

# No public invoker binding, unlike the share function: the trigger is the only
# caller, and a client never invokes this.
