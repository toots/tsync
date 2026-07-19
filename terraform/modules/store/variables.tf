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

variable "shares_prefix" {
  type        = string
  default     = ".shares/"
  description = "Key prefix for share manifests + cached artifacts: \"<domain-prefix>/.shares/\" or \".shares/\"."
}

variable "manage_lifecycle" {
  type        = bool
  default     = true
  description = "Manage the bucket lifecycle config. False = leave it untouched (add your own shares-prefix expiry)."
}

variable "cache_expiry_days" {
  type        = number
  default     = 30
  description = "Days before share manifests + cached artifacts are deleted. Keep >= longest `tsync share --expires`."
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
