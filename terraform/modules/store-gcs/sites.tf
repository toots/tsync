# The sites bucket of site shares (11 §7, infrastructure/gcs.md §4, §7, §9), set
# by var.sites_bucket: public reads of objects, no listing, written by the share
# function alone and served through it on the sites domain.

locals {
  sites_enabled = var.sites_bucket != null && var.sites_domain != null && var.deploy_share ? 1 : 0
}

resource "google_storage_bucket" "sites" {
  count                       = local.sites_enabled
  name                        = var.sites_bucket
  location                    = var.location
  uniform_bucket_level_access = true
  public_access_prevention    = "inherited"

  # A published page's scripts fetch the files the function redirects them to.
  cors {
    origin          = ["https://${var.sites_domain}"]
    method          = ["GET", "HEAD"]
    response_header = ["Content-Range", "Content-Length", "Content-Type", "Accept-Ranges"]
    max_age_seconds = 3600
  }

  lifecycle_rule {
    condition { age = 1 }
    action { type = "AbortIncompleteMultipartUpload" }
  }

  # The function sets each object's customTime to its share's expiry, which
  # makes this rule the sweep; the provider drops a zero unless told to send it.
  lifecycle_rule {
    condition {
      days_since_custom_time              = 0
      send_days_since_custom_time_if_zero = true
    }
    action { type = "Delete" }
  }
}

# Reads an object, and never lists the bucket, which objectViewer would.
resource "google_storage_bucket_iam_member" "sites_public" {
  count  = local.sites_enabled
  bucket = google_storage_bucket.sites[0].name
  role   = "roles/storage.legacyObjectReader"
  member = "allUsers"
}

resource "google_storage_bucket_iam_member" "sites_share" {
  count  = local.sites_enabled
  bucket = google_storage_bucket.sites[0].name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.share[0].email}"
}

resource "google_cloud_run_domain_mapping" "sites" {
  count    = local.sites_enabled
  location = var.function_region
  name     = var.sites_domain

  metadata {
    namespace = var.project
  }

  spec {
    route_name = google_cloudfunctions2_function.share[0].name
  }
}
