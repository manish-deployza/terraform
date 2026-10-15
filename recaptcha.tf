# Score-based (invisible) reCAPTCHA Enterprise key for the HR web domain.
# hr-ui must load the widget with this site key and hr-server must verify the token.
resource "google_recaptcha_enterprise_key" "hr_web" {
  depends_on = [google_project_service.apis]

  display_name = "hr-web"
  project      = var.project
  labels       = var.labels

  web_settings {
    integration_type  = "SCORE"
    allow_all_domains = false
    allowed_domains   = [var.domain]
  }
}
