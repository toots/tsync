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

variable "shares_prefix" {
  type        = string
  description = "Key prefix for share manifests + cached artifacts. tsync stores them at \"tsync/<domain>/shares/\" — set this to that exact value for the domain served by this store."
}

variable "manage_lifecycle" {
  type        = bool
  default     = true
  description = "Manage the bucket lifecycle (shares-prefix expiry). Only applies when create_bucket = true — GCS lifecycle is a property of the bucket, not a separate resource."
}

variable "cache_expiry_days" {
  type        = number
  default     = 30
  description = "Days before share manifests + cached artifacts are deleted. Keep >= longest `tsync share --expires`."
}

variable "archive_after_days" {
  type        = number
  default     = null
  description = "When set, transition ALL objects to the ARCHIVE (cold) storage class after this many days. Opt-in per store; left null (off) by default. Only applies when create_bucket = true."
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
