# Global external Application Load Balancer in front of hr-server1.
# HTTPS (443) terminates here with a Google-managed cert; HTTP (80) redirects to HTTPS.

locals {
  # Google front ends and health checkers reach backends from these ranges
  google_lb_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
}

resource "google_compute_global_address" "lb_ip" {
  depends_on = [google_project_service.apis]

  name   = "hr-lb-ip"
  labels = var.labels
}

# The LB can't target a bare VM, so wrap it in an unmanaged instance group
resource "google_compute_instance_group" "hr_web" {
  name      = "hr-web-ig"
  zone      = var.zone
  instances = [google_compute_instance.hr_server1.self_link]

  named_port {
    name = "http"
    port = 80
  }
}

resource "google_compute_health_check" "hr_web" {
  name                = "hr-web-hc"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 80
    request_path = "/login.html" # "/" redirects, and health checks need a 200
  }
}

resource "google_compute_backend_service" "hr_web" {
  name                  = "hr-web-backend"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.hr_web.id]

  backend {
    group = google_compute_instance_group.hr_web.id
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_managed_ssl_certificate" "hr" {
  name = "hr-managed-cert"

  managed {
    domains = [var.domain]
  }
}

resource "google_compute_url_map" "https" {
  name            = "hr-https-map"
  default_service = google_compute_backend_service.hr_web.id
}

resource "google_compute_target_https_proxy" "https" {
  name             = "hr-https-proxy"
  url_map          = google_compute_url_map.https.id
  ssl_certificates = [google_compute_managed_ssl_certificate.hr.id]
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "hr-https-rule"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb_ip.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.https.id
  labels                = var.labels
}

resource "google_compute_url_map" "http_redirect" {
  name = "hr-http-redirect-map"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "http_redirect" {
  name    = "hr-http-redirect-proxy"
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http_redirect" {
  name                  = "hr-http-rule"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb_ip.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.http_redirect.id
  labels                = var.labels
}

# Health checks and proxied traffic only; always on, independent of restrict_web_to_lb
resource "google_compute_firewall" "hr_allow_lb" {
  depends_on = [google_project_service.apis]

  name    = "hr-allow-lb"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = local.google_lb_ranges
  target_tags   = ["hr-web"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
