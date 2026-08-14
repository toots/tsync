variable "region" {
  type        = string
  default     = null
  description = "AWS region for s3 stores. Required only when stores is non-empty (leave unset for a GCS-only deployment). For buckets in different regions, see README > Multi-region."
}

# ── GCS ────────────────────────────────────────────────────────────────────

variable "gcp_project" {
  type        = string
  default     = null
  description = "GCP project id. Required only when gcs_stores is non-empty."
}

variable "gcp_region" {
  type        = string
  default     = null
  description = "Default bucket location for GCS stores — region or multi-region (US, EU). Required only when gcs_stores is non-empty."
}

variable "gcp_function_region" {
  type        = string
  default     = "us-central1"
  description = "Default region for share Cloud Functions. Must be a specific region (not a multi-region like US), since Cloud Functions/Run are regional."
}

variable "gcp_functions_source_bucket" {
  type        = string
  default     = null
  description = "Bucket to hold the function source zip. Defaults to <project>-tsync-functions-src."
}

variable "gcs_stores" {
  description = <<-EOT
    GCS stores to provision, keyed by a short logical name ([a-z0-9-], suffixes
    SA/function names). One entry = one bucket + client SA key + share Cloud
    Function + lifecycle. Uses native OAuth (service-account key), not S3 interop.
  EOT
  type = map(object({
    bucket             = string
    create_bucket      = optional(bool, true)
    location           = optional(string) # bucket location; default: var.gcp_region
    function_region    = optional(string) # default: var.gcp_function_region
    custom_domain      = optional(string) # vanity share domain; null = raw function URL
    manage_lifecycle   = optional(bool, true)
    share_expiry_days  = optional(number, 30)
    archive_after_days = optional(number) # null = no cold-storage transition; keep > share_expiry_days
    presign_ttl        = optional(number, 600)
    memory_mb          = optional(number, 2048)
    # Domains whose chunks live in this bucket. Empty deploys no verifier: see
    # modules/store-gcs/variables.tf for why there is no safe default.
    chunk_domains          = optional(list(string), [])
    verify_timeout_seconds = optional(number, 120)
    verify_memory_mb       = optional(number, 512)
    verify_max_concurrency = optional(number, 32)
    max_share_bytes        = optional(number, 10737418240)
  }))
  default = {}
}

variable "stores" {
  description = <<-EOT
    Stores to provision, keyed by a short logical name ([A-Za-z0-9-_], suffixes
    IAM/Lambda names). One entry = one bucket + client IAM keys + share Lambda +
    lifecycle. Add entries for more domains or redundant storage.
  EOT
  type = map(object({
    bucket               = string
    create_bucket        = optional(bool, true)
    iam_user_name        = optional(string) # default: tsync-client-<key>
    custom_domain        = optional(string) # vanity share domain; null = raw Lambda URL
    manage_lifecycle     = optional(bool, true)
    share_expiry_days    = optional(number, 30)
    archive_after_days   = optional(number) # null = no cold-storage transition (GLACIER_IR); keep > share_expiry_days
    presign_ttl          = optional(number, 600)
    lambda_memory_mb     = optional(number, 2048)
    ephemeral_storage_mb = optional(number, 10240)
    # Domains whose chunks live in this bucket, e.g. ["photos"]. Empty deploys
    # no verifier: see modules/store-s3/variables.tf for why there is no safe
    # default. A prefix that matches nothing looks exactly like a clean store.
    chunk_domains          = optional(list(string), [])
    manage_notifications   = optional(bool, true)
    verify_timeout_seconds = optional(number, 120)
    verify_memory_mb       = optional(number, 512)
    extra_lifecycle_rules = optional(list(object({
      id              = string
      prefix          = optional(string, "")
      expiration_days = optional(number)
      transitions = optional(list(object({
        days          = number
        storage_class = string
      })), [])
    })), [])
  }))
  default = {}
}
