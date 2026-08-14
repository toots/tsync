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
  description = "Vanity domain for share links (e.g. share.example.org). null = raw function URL, no load balancer. See domain.tf."
}

variable "manage_lifecycle" {
  type        = bool
  default     = true
  description = "Manage the bucket lifecycle (shares-prefix expiry). Only applies when create_bucket = true — GCS lifecycle is a property of the bucket, not a separate resource."
}

variable "share_expiry_days" {
  type        = number
  default     = 30
  description = "Days before share manifests + cached artifacts are deleted. Keep >= longest `tsync share --expires`, and below archive_after_days if that's set — otherwise share caches could transition to ARCHIVE before they're deleted."
}

variable "archive_after_days" {
  type        = number
  default     = null
  description = "When set, transition ALL objects to the ARCHIVE (cold) storage class after this many days. Opt-in per store; left null (off) by default. Only applies when create_bucket = true. Keep above share_expiry_days — shares are deleted, not meant to archive."
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

variable "chunk_domains" {
  type        = list(string)
  default     = []
  description = <<-EOT
    tsync domain names whose chunks live in this bucket, e.g. ["photos"] for
    objects under tsync/photos/chunks/. Each gets a storage notification that
    checks the chunk against its own name.

    Empty (the default) deploys nothing. There is no safe guess: the store name
    and the domain name are only conventionally equal, and a prefix that matches
    nothing means a function that never fires — indistinguishable from a store
    with no corruption. Set this to the domain names in the daemon's config, and
    set each backend's verifyChunks accordingly so `tsync verify` knows whether
    to trust the answer.
  EOT
}

variable "verify_timeout_seconds" {
  type        = number
  default     = 120
  description = "Per-object timeout for the chunk verifier. One chunk per invocation, so this is a stall guard rather than a budget."
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
