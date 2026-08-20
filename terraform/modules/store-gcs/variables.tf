variable "name" {
  type        = string
  description = "Logical store name; suffixes SA/function names, so keep it short and unique ([a-z0-9-])."
}

variable "bucket" {
  type        = string
  description = "GCS bucket name (created unless create_bucket = false)."
}

variable "create_bucket" {
  type        = bool
  default     = true
  description = "Create and manage the bucket (uniform access, public access prevented). False = use a pre-existing bucket; its access settings and lifecycle are left untouched."
}

variable "location" {
  type        = string
  description = "Bucket location — may be a region (us-central1) or multi-region (US, EU)."
}

variable "function_region" {
  type        = string
  description = "Region for the share Cloud Function. Must be a specific region (e.g. us-central1), not a multi-region like US."
}

variable "custom_domain" {
  type        = string
  default     = null
  description = "Vanity domain for share links (e.g. share.example.org). null = raw function URL. Requires the parent domain to be verified for the deploying account; see domain.tf."
}

variable "manage_lifecycle" {
  type        = bool
  default     = true
  description = "Manage the bucket lifecycle (abandoned-upload cleanup + archive_domains). Only applies when create_bucket = true — GCS lifecycle is a property of the bucket, not a separate resource."
}

variable "archive_domains" {
  type = map(object({
    after_days    = number
    storage_class = optional(string)
  }))
  default     = {}
  description = <<-EOT
    Cold-storage transition per tsync domain, keyed by domain name: chunks under
    tsync/<domain>/chunks/ move to storage_class after after_days. Off by
    default, and it reaches nothing else — manifests, versions, the journal, the
    cursor and tsync/shares/ are read far too often to archive.

    The domain has to be named because it sits in the middle of a chunk key and
    matches_prefix holds literal prefixes: no wildcard spans domains, and a
    domain left out simply never archives.

    storage_class defaults to ARCHIVE. Only applies when create_bucket = true.
  EOT

  # Deliberately only "not a path": a domain name is free-form and may well
  # carry spaces and capitals, so anything stricter would reject real domains.
  validation {
    condition     = alltrue([for domain in keys(var.archive_domains) : domain != "" && !strcontains(domain, "/")])
    error_message = "archive_domains keys are tsync domain names, not paths: a key with a slash would silently retarget the prefix."
  }

  # Siblings of the domain folders under tsync/, not domains. Naming one builds
  # a prefix like "tsync/shares/chunks/" that matches nothing, silently.
  validation {
    condition     = length(setintersection(keys(var.archive_domains), ["shares", "corrupted", "verify-jobs", "gc-jobs"])) == 0
    error_message = "archive_domains: shares, corrupted, verify-jobs and gc-jobs are store-level prefixes, not domains."
  }

  validation {
    condition     = alltrue([for cfg in values(var.archive_domains) : cfg.after_days > 0])
    error_message = "archive_domains after_days must be positive."
  }

  validation {
    condition = alltrue([
      for cfg in values(var.archive_domains) : cfg.storage_class == null || contains(
      ["NEARLINE", "COLDLINE", "ARCHIVE"], cfg.storage_class)
    ])
    error_message = "archive_domains storage_class must be one of NEARLINE, COLDLINE, ARCHIVE."
  }

  # A bucket takes 100 lifecycle rules; the abort rule is one of them.
  validation {
    condition     = length(var.archive_domains) <= 99
    error_message = "archive_domains: a GCS bucket accepts at most 100 lifecycle rules."
  }
}

variable "presign_ttl" {
  type        = number
  default     = 600
  description = "Lifetime (seconds) of the V4 signed download URL."
}

variable "memory_mb" {
  type        = number
  default     = 2048
  description = "Function memory (MB). Note: on Cloud Functions gen2, /tmp is RAM-backed, so folder-zip assembly is bounded by this — keep max_share_bytes below it."
}

variable "timeout_seconds" {
  type    = number
  default = 900
}

variable "max_share_bytes" {
  type        = number
  default     = 10737418240 # 10 GiB
  description = "Reject assembling a single file or folder zip larger than this (bytes) with 413. Keep below memory_mb for folder zips (see memory_mb)."
}

variable "source_bucket" {
  type        = string
  description = "GCS bucket holding the function source zip."
}

variable "source_zip" {
  type        = string
  description = "Path to the packaged handler zip (built once at the root)."
}

variable "source_hash" {
  type        = string
  description = "base64 sha256 of the source zip, for redeploy detection."
}

# ── Chunk verification ─────────────────────────────────────────────────────

variable "verify_timeout_seconds" {
  type        = number
  default     = 120
  description = "Timeout for the chunk verifier. One chunk per upload event, or one batch of chunk deletes per gc request, so this is a stall guard rather than a budget."
}

variable "verify_memory_mb" {
  type        = number
  default     = 512
  description = "Memory for the chunk verifier; the work is dominated by reading one chunk."
}

variable "project" {
  type        = string
  description = "GCP project id. Needed explicitly for the project-level IAM binding the chunk verifier's trigger requires; every other resource here takes it from the provider."
}

variable "verify_max_instances" {
  type        = number
  default     = 32
  description = "Ceiling on concurrent chunk-verifier instances. A whole-store sweep makes one request per shard (4096) deliverable at once; this is what stops that from being 4096 concurrent readers."
}

variable "deploy_share" {
  type    = bool
  default = true
  # False deploys the verification half alone: the chunk verifier, its trigger
  # and the client credentials, without the share function or the public
  # endpoint that fronts it. That is what a bucket used only for testing wants —
  # nothing there serves links, and an unauthenticated URL over it would be
  # surface for no purpose.
  description = "Deploy the share function and its public endpoint. False = verification half only."
}
