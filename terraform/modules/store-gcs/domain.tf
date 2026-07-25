# Optional vanity domain for share links. Everything here is gated on
# var.custom_domain: leave it null and the store serves off the raw Cloud
# Function URL with no load balancer, no cert, and no DNS to manage.
#
# GCP has no API-Gateway-style "cert on a function URL", so a custom HTTPS domain
# means fronting the function's Cloud Run service with an external HTTPS load
# balancer + a Google-managed cert. Requires the Compute Engine API
# (compute.googleapis.com) enabled, and the load balancer carries an hourly cost.
#
# DNS is intentionally NOT created here — it works with any provider. After apply
# add ONE record: an A record from custom_domain -> custom_domain_ip (output). The
# managed cert then provisions on its own (~15-60 min; apply does not block on it).

locals {
  domain_enabled = var.custom_domain == null ? 0 : 1
}

# The A-record target: a global anycast IP for the load balancer.
resource "google_compute_global_address" "share" {
  count = local.domain_enabled
  name  = "tsync-share-${var.name}-ip"
}

# Serverless NEG -> the function's Cloud Run service (same name as the function).
resource "google_compute_region_network_endpoint_group" "share" {
  count                 = local.domain_enabled
  name                  = "tsync-share-${var.name}-neg"
  region                = var.function_region
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = google_cloudfunctions2_function.share.name
  }
}

resource "google_compute_backend_service" "share" {
  count                 = local.domain_enabled
  name                  = "tsync-share-${var.name}-be"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  backend {
    group = google_compute_region_network_endpoint_group.share[0].id
  }
}

resource "google_compute_url_map" "share" {
  count           = local.domain_enabled
  name            = "tsync-share-${var.name}-um"
  default_service = google_compute_backend_service.share[0].id
}

# Google-managed cert. Provisions once custom_domain resolves to the LB IP; stays
# in PROVISIONING until then (no Terraform blocking wait, unlike AWS ACM).
resource "google_compute_managed_ssl_certificate" "share" {
  count = local.domain_enabled
  name  = "tsync-share-${var.name}-cert"
  managed {
    domains = [var.custom_domain]
  }
}

resource "google_compute_target_https_proxy" "share" {
  count            = local.domain_enabled
  name             = "tsync-share-${var.name}-proxy"
  url_map          = google_compute_url_map.share[0].id
  ssl_certificates = [google_compute_managed_ssl_certificate.share[0].id]
}

# HTTPS only (no port-80 rule; managed-cert provisioning needs only DNS -> IP).
resource "google_compute_global_forwarding_rule" "share" {
  count                 = local.domain_enabled
  name                  = "tsync-share-${var.name}-fr"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_https_proxy.share[0].id
  ip_address            = google_compute_global_address.share[0].id
  port_range            = "443"
}
