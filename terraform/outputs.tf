# Member names are the backend's own field names, so a store's entry here and in
# store_secrets merge into a tsync backend with nothing translated. shareUrl is
# null without a share function, which the backends read as none.
output "stores" {
  description = "Per store: its backend type and every non-secret backend field the deployment decides."
  value = merge(
    {
      for name, store in module.store : name => {
        type        = "s3"
        bucket      = store.bucket
        region      = store.region
        accessKeyId = store.access_key_id
        shareUrl    = store.share_url
      }
    },
    {
      for name, store in module.store_gcs : name => {
        type     = "gcs"
        bucket   = store.bucket
        shareUrl = store.share_url
      }
    },
  )
}

output "store_secrets" {
  description = "Per store: the secret fields of its backend."
  sensitive   = true
  value = merge(
    { for name, store in module.store : name => { secretAccessKey = store.secret_access_key } },
    { for name, store in module.store_gcs : name => { serviceAccountKey = store.service_account_key } },
  )
}

output "custom_domain_dns" {
  description = "Per store with a custom domain: the domain and the DNS records to publish."
  value = {
    for name, store in merge(module.store, module.store_gcs) : name => {
      domain  = store.custom_domain
      records = store.custom_domain_dns_records
    } if store.custom_domain != null
  }
}
