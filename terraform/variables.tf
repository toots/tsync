variable "region" {
  type        = string
  default     = null
  description = "Default AWS region of an s3 store. Required only when stores is non-empty."
}

variable "gcp_project" {
  type        = string
  default     = null
  description = "GCP project id. Required only when gcs_stores is non-empty."
}

variable "gcp_region" {
  type        = string
  default     = null
  description = "Default bucket location of a GCS store, a region or a multi-region (US, EU), and the location of the function source bucket. Required only when gcs_stores is non-empty."
}

variable "gcp_function_region" {
  type        = string
  default     = "us-central1"
  description = "Default region of a GCS store's functions. A region, never a multi-region."
}

variable "gcp_functions_source_bucket" {
  type        = string
  default     = null
  description = "Bucket holding the function package. Defaults to <project>-tsync-functions-src."
}

# The options both maps share carry the same names; an option left out takes
# the default its store module declares (docs/spec/11-infrastructure.md §10).

variable "stores" {
  description = "S3 stores, keyed by store name. A name is unique across stores and gcs_stores."
  type = map(object({
    bucket        = string
    create_bucket = optional(bool)
    share         = optional(bool)
    custom_domain = optional(string)
    archive_domains = optional(map(object({
      after_days    = number
      storage_class = optional(string) # default: GLACIER_IR
    })), {})
    presign_ttl            = optional(number)
    max_share_bytes        = optional(number)
    share_memory_mb        = optional(number)
    verify_timeout_seconds = optional(number)
    verify_memory_mb       = optional(number)
    verify_max_concurrency = optional(number)

    region               = optional(string) # default: var.region
    iam_user_name        = optional(string) # default: tsync-client-<name>
    manage_lifecycle     = optional(bool)
    manage_notifications = optional(bool)
    share_scratch_mb     = optional(number)
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

  validation {
    condition     = alltrue([for name in keys(var.stores) : can(regex("^[A-Za-z0-9_-]{1,51}$", name))])
    error_message = "An s3 store name is 1 to 51 letters, digits, dashes and underscores."
  }
}

variable "gcs_stores" {
  description = "GCS stores, keyed by store name. A name is unique across stores and gcs_stores."
  type = map(object({
    bucket        = string
    create_bucket = optional(bool)
    share         = optional(bool)
    custom_domain = optional(string)
    archive_domains = optional(map(object({
      after_days    = number
      storage_class = optional(string) # default: ARCHIVE
    })), {})
    presign_ttl            = optional(number)
    max_share_bytes        = optional(number)
    share_memory_mb        = optional(number)
    verify_timeout_seconds = optional(number)
    verify_memory_mb       = optional(number)
    verify_max_concurrency = optional(number)

    location        = optional(string) # default: var.gcp_region
    function_region = optional(string) # default: var.gcp_function_region
  }))
  default = {}
}
