variable "name" {
  type        = string
  description = "Logical store name; suffixes IAM/Lambda resource names, so keep it short and unique ([A-Za-z0-9-_])."
}

variable "bucket" {
  type        = string
  description = "S3 bucket name (created unless create_bucket = false)."
}

variable "create_bucket" {
  type        = bool
  default     = true
  description = "Create and manage the bucket (public access blocked, TLS-only). False = use a pre-existing bucket read-only."
}

variable "iam_user_name" {
  type        = string
  default     = null
  description = "IAM user for tsync clients. Defaults to tsync-client-<name>."
}

variable "manage_lifecycle" {
  type        = bool
  default     = true
  description = "Manage the bucket lifecycle config. False = leave it untouched (add your own shares-prefix expiry)."
}

variable "share_expiry_days" {
  type        = number
  default     = 30
  description = "Days before share manifests + cached artifacts are deleted. Keep >= longest `tsync share --expires`, and below archive_after_days if that's set — otherwise share caches could transition to GLACIER_IR before they're deleted."
}

variable "archive_after_days" {
  type        = number
  default     = null
  description = "When set, transition ALL objects to the GLACIER_IR (cold, instant-retrieval) storage class after this many days. Opt-in per store; left null (off) by default. Keep above share_expiry_days — shares are deleted, not meant to archive."
}

variable "extra_lifecycle_rules" {
  type = list(object({
    id              = string
    prefix          = optional(string, "")
    expiration_days = optional(number)
    transitions = optional(list(object({
      days          = number
      storage_class = string
    })), [])
  }))
  default     = []
  description = "Existing bucket lifecycle rules to preserve alongside the shares rule."
}

variable "presign_ttl" {
  type        = number
  default     = 600
  description = "Lifetime (seconds) of the presigned download URL."
}

variable "custom_domain" {
  type        = string
  default     = null
  description = <<-EOT
    Optional vanity domain for share links, e.g. "tsync.example.org". When set,
    the store also provisions an API Gateway HTTP API + regional ACM cert (DNS
    validation) fronting the Lambda, and share_url points at it. When null the
    store just uses the raw Lambda Function URL — no DNS setup needed.

    DNS is not managed here: after apply, add the acm_validation_records CNAME to
    validate the cert, then CNAME the domain to custom_domain_target. See README.
  EOT
}

variable "lambda_memory_mb" {
  type    = number
  default = 2048
}

variable "ephemeral_storage_mb" {
  type    = number
  default = 10240
}

variable "max_share_bytes" {
  type        = number
  default     = 10737418240 # 10 GiB
  description = "Reject assembling a single file or folder zip larger than this (bytes) with 413. Keep below the /tmp ephemeral size for zips."
}

variable "lambda_zip" {
  type        = string
  description = "Path to the packaged Lambda handler zip (built once at the root)."
}

variable "lambda_zip_hash" {
  type        = string
  description = "base64 sha256 of the Lambda zip, for redeploy detection."
}

# ── Chunk verification ─────────────────────────────────────────────────────

variable "chunk_domains" {
  type        = list(string)
  default     = []
  description = <<-EOT
    tsync domain names whose chunks live in this bucket, e.g. ["photos"] for
    keys under tsync/photos/chunks/. Each gets an object-created trigger that
    checks the chunk against its own name.

    Empty (the default) deploys nothing. There is no safe guess: the store name
    and the domain name are only conventionally equal, and a wrong prefix means
    a function that never fires — which looks exactly like a store with no
    corruption. Set this to the domain names in the daemon's config, and set
    each backend's verifyChunks accordingly so `tsync verify` knows to trust
    the answer.
  EOT
}

variable "manage_notifications" {
  type        = bool
  default     = true
  description = "Manage the bucket's notification config. aws_s3_bucket_notification owns it entirely, so this REPLACES any notification already on the bucket. False = leave it untouched and wire the verify function yourself."
}

variable "verify_timeout_seconds" {
  type        = number
  default     = 120
  description = "Per-object timeout for the chunk verifier. One chunk per invocation, so this is a stall guard rather than a budget."
}

variable "verify_memory_mb" {
  type        = number
  default     = 512
  description = "Memory for the chunk verifier. Lambda scales CPU and network with memory, and the work is dominated by reading one chunk."
}
