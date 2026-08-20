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
  description = "Manage the bucket lifecycle config. aws_s3_bucket_lifecycle_configuration owns it entirely, so this REPLACES any rules already on the bucket. False = leave it untouched, and nothing aborts abandoned multipart uploads."
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
    an S3 rule filter holds one literal prefix: no wildcard spans domains, and a
    domain left out simply never archives.

    storage_class defaults to GLACIER_IR (cold, instant retrieval).
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
        ["STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"],
      cfg.storage_class)
    ])
    error_message = "archive_domains storage_class must be one of STANDARD_IA, ONEZONE_IA, INTELLIGENT_TIERING, GLACIER_IR, GLACIER, DEEP_ARCHIVE."
  }

  # AWS rejects the whole configuration if either IA class is asked for sooner.
  validation {
    condition = alltrue([
      for cfg in values(var.archive_domains) :
      cfg.after_days >= 30
      if contains(["STANDARD_IA", "ONEZONE_IA"], coalesce(cfg.storage_class, "GLACIER_IR"))
    ])
    error_message = "archive_domains: STANDARD_IA and ONEZONE_IA require after_days >= 30."
  }
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
  description = "Existing bucket lifecycle rules to preserve alongside the module's own."
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

variable "manage_notifications" {
  type        = bool
  default     = true
  description = "Manage the bucket's notification config. aws_s3_bucket_notification owns it entirely, so this REPLACES any notification already on the bucket. False = leave it untouched and wire the verify function yourself."
}

variable "verify_timeout_seconds" {
  type        = number
  default     = 120
  description = "Timeout for the chunk verifier. One chunk per upload event, or one batch of chunk deletes per gc request, so this is a stall guard rather than a budget."
}

variable "verify_memory_mb" {
  type        = number
  default     = 512
  description = "Memory for the chunk verifier. Lambda scales CPU and network with memory, and the work is dominated by reading one chunk."
}

variable "verify_max_concurrency" {
  type        = number
  default     = 32
  description = "Ceiling on concurrent chunk-verifier invocations. A whole-store sweep queues one request per shard (4096) and they become deliverable at once; this is what stops that from being 4096 concurrent readers. -1 removes the ceiling."
}

variable "deploy_share" {
  type    = bool
  default = true
  # False deploys the verification half alone: the chunk verifier, its trigger
  # and the client credentials, without the share Lambda or the unauthenticated
  # function URL that fronts it. That is what a bucket used only for testing
  # wants -- nothing there serves links, and a public URL over it would be
  # surface for no purpose.
  description = "Deploy the share Lambda and its public function URL. False = verification half only."
}
