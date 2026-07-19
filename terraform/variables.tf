variable "region" {
  type        = string
  description = "AWS region for all stores. For buckets in different regions, see README > Multi-region."
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
    shares_prefix        = string           # "tsync/<domain>/shares/"
    manage_lifecycle     = optional(bool, true)
    cache_expiry_days    = optional(number, 30)
    presign_ttl          = optional(number, 600)
    lambda_memory_mb     = optional(number, 2048)
    ephemeral_storage_mb = optional(number, 10240)
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
}
