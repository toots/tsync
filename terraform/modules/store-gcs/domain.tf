# Optional vanity domain for share links, gated on var.custom_domain: leave it
# null and the store serves off the raw Cloud Function URL with no cert and no
# DNS to manage.
#
# Cloud Run serves the domain and renews its cert itself, which keeps the store
# clear of a load balancer's hourly forwarding-rule charge at the price of no
# path routing, CDN or Cloud Armor, and only in the regions Cloud Run maps
# domains in. The parent domain has to be verified for the deploying account
# first, which Terraform cannot do.
#
# DNS is intentionally NOT created here — it works with any provider. After apply
# publish the records from the gcs_custom_domain_dns output; the cert provisions
# on its own once they resolve (apply does not block on it).

locals {
  # A vanity domain maps onto the share service, so there is nothing to map when
  # the store was deployed without one.
  domain_enabled = var.custom_domain == null || !var.deploy_share ? 0 : 1
}

# status.resource_records carries the DNS to publish — a CNAME for a subdomain,
# A/AAAA sets for an apex.
resource "google_cloud_run_domain_mapping" "share" {
  count    = local.domain_enabled
  location = var.function_region
  name     = var.custom_domain

  metadata {
    namespace = var.project
  }

  spec {
    route_name = google_cloudfunctions2_function.share[0].name
  }
}
