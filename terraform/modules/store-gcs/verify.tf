# ── Chunk verification ─────────────────────────────────────────────────────
#
# Mirrors modules/store-s3/verify.tf on the google provider: each stored chunk
# held against its own name, on the bucket's object-created event, one object
# per invocation, filing what fails under tsync/corrupted/.
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
      "resource.name.startsWith(\"projects/_/buckets/${local.bucket_name}/objects/tsync/gc-jobs/\")",
    ])
  }
}

# Drop chunks on a collection's behalf: delete alone, in its own role, because
# objectUser above also carries create and this function must never write a
# chunk — a wrong body would be silent where a wrong delete is at least visible.
resource "google_project_iam_custom_role" "chunk_deleter" {
  role_id     = replace("tsyncChunkDeleter_${var.name}", "-", "_")
  title       = "tsync chunk deleter (${var.name})"
  description = "Delete chunks a tsync collection found unreferenced."
  permissions = ["storage.objects.delete"]
  project     = var.project
}

# `extract` rather than startsWith, the one shape a condition cannot spell:
# chunks are "tsync/<domain>/chunks/" with the domain in the middle, which is
# why markers and requests are namespaced the other way round. A non-empty
# extraction means the object is some domain's chunk.
#
# If this expression is ever rejected, it fails at apply and — were it to fail
# quietly instead — the function's deletes are refused, which leaves the request
# in the bucket for `tsync gc --status` to report. Fail-closed either way.
resource "google_storage_bucket_iam_member" "verify_drop_chunks" {
  bucket = local.bucket_name
  role   = google_project_iam_custom_role.chunk_deleter.id
  member = "serviceAccount:${google_service_account.verify.email}"
  condition {
    title      = "chunk-namespace-only"
    expression = "resource.name.extract(\"projects/_/buckets/${local.bucket_name}/objects/tsync/{domain}/chunks/\") != \"\""
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

# One notification for all three: a chunk, a sweep request and a delete request
# all live under tsync/, and the function decides which it was handed — which it
# does anyway, since a filter is configuration and the code cannot lean on it.
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
    available_memory = "${var.verify_memory_mb}M"
    timeout_seconds  = var.verify_timeout_seconds

    # A whole-store sweep makes one request per shard deliverable at once.
    # Unbounded, that is thousands of concurrent readers against one bucket.
    max_instance_count    = var.verify_max_instances
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
    # chunk in it forever, where a dropped event costs only a missed marker.
    retry_policy          = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.verify.email
  }
}

# A gen2 function is a Cloud Run service, and Eventarc invokes it as one — so the
# trigger's own service account has to be allowed to invoke it. Without this the
# events arrive and every one is rejected with "The IAM principal lacks
# run.routes.invoke", which looks from the client's side exactly like a trigger
# that was never wired: requests queue up and nothing consumes them.
#
# The account, not allUsers as the share function needs: the trigger is the only
# caller, and a client never invokes this.
resource "google_cloud_run_v2_service_iam_member" "verify_invoker" {
  location = google_cloudfunctions2_function.verify.location
  name     = google_cloudfunctions2_function.verify.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.verify.email}"
}

