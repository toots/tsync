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
# filter at all, so it would invoke this on everything in the bucket rather than
# on what tsync owns.

resource "google_service_account" "verify" {
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
  bucket = local.bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.verify.email}"
}

# Write and clear markers, and nothing else. Delete matters as much as write: a
# marker is cleared by the very write that fixed the chunk.
resource "google_storage_bucket_iam_member" "verify_mark" {
  bucket = local.bucket_name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.verify.email}"
  condition {
    title = "corrupted-prefix-only"
    # Two literal prefixes. IAM conditions offer only startsWith on
    # resource.name — no contains, no wildcard — which is exactly why markers
    # and requests are namespaced with the domain inside rather than around
    # them: "tsync/<domain>/corrupted/" could not be expressed here at all.
    expression = join(" || ", [
      "resource.name.startsWith(\"projects/_/buckets/${local.bucket_name}/objects/tsync/corrupted/\")",
      "resource.name.startsWith(\"projects/_/buckets/${local.bucket_name}/objects/tsync/verify-jobs/\")",
    ])
  }
}

# ── The trigger ────────────────────────────────────────────────────────────

resource "google_pubsub_topic" "chunks" {
  name = "tsync-chunks-${var.name}"
}

# Cloud Storage publishes as its own per-project service agent, which has no
# rights on a new topic until granted them.
data "google_storage_project_service_account" "gcs" {
}

resource "google_pubsub_topic_iam_member" "gcs_publisher" {
  topic  = google_pubsub_topic.chunks.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

# One notification for both: a chunk and a sweep request both live under tsync/,
# and the function decides which it was handed — which it does anyway, since a
# filter is configuration and the code cannot lean on it.
#
# The function writes markers into the bucket it watches, so its own writes come
# back to it. That terminates rather than loops: marker_key() returns None for a
# marker, so the second invocation reads nothing and writes nothing.
resource "google_storage_notification" "chunks" {
  bucket             = local.bucket_name
  topic              = google_pubsub_topic.chunks.id
  payload_format     = "JSON_API_V1"
  event_types        = ["OBJECT_FINALIZE"]
  object_name_prefix = "tsync/"

  # The binding must exist first or the notification is rejected.
  depends_on = [google_pubsub_topic_iam_member.gcs_publisher]
}

# The only resource here that needs the project spelled out; the rest take it
# from the provider.
resource "google_project_iam_member" "verify_receiver" {
  project = var.project
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.verify.email}"
}

resource "google_cloudfunctions2_function" "verify" {
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
    service_account_email = google_service_account.verify.email
    environment_variables = {
      BUCKET = local.bucket_name
      STORE  = "gcs"
    }
  }

  event_trigger {
    trigger_region = var.function_region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.chunks.id
    # A bucket the function cannot read would otherwise retry against every
    # chunk in it, forever. A dropped event costs a missed marker, which is
    # exactly what the store looked like before any of this existed.
    retry_policy          = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.verify.email
  }
}

# No public invoker binding, unlike the share function: the trigger is the only
# caller, and a client never invokes this.

