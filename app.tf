# Runtime wiring for the deploy script (deploy.sh.tftpl): DB password, bucket and secret access for the VM.

# The password lives in Secret Manager (and in the access-restricted state bucket), never in code or metadata
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "google_secret_manager_secret" "db_password" {
  depends_on = [google_project_service.apis]

  secret_id = "hr-db-password"
  project   = var.project
  labels    = var.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

resource "google_secret_manager_secret_iam_member" "vm_db_password" {
  project   = var.project
  secret_id = google_secret_manager_secret.db_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.hr_server1.email}"
}

resource "google_storage_bucket_iam_member" "vm_war_reader" {
  bucket = google_storage_bucket.war_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.hr_server1.email}"
}

# Lets hr-server verify reCAPTCHA tokens (createAssessment)
resource "google_project_iam_member" "vm_recaptcha" {
  project = var.project
  role    = "roles/recaptchaenterprise.agent"
  member  = "serviceAccount:${google_service_account.hr_server1.email}"
}

# ---- Backend runtime config -------------------------------------------------
# Non-secret settings and secret names are rendered into the VM boot script, which writes
# /etc/hr/app.env (root-only) for Tomcat. Secrets with no value yet are skipped, not fatal.

# Signing key for login sessions (backend needs >= 32 bytes)
resource "random_password" "jwt" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "jwt" {
  depends_on = [google_project_service.apis]

  secret_id = "hr-jwt-secret"
  project   = var.project
  labels    = var.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "jwt" {
  secret      = google_secret_manager_secret.jwt.id
  secret_data = random_password.jwt.result
}

# Third-party credentials: Terraform creates the empty secret, values are added with
# `gcloud secrets versions add <id> --data-file=-` so they never enter code or state.
resource "google_secret_manager_secret" "external" {
  for_each   = toset(var.external_secret_ids)
  depends_on = [google_project_service.apis]

  secret_id = each.value
  project   = var.project
  labels    = var.labels

  replication {
    auto {}
  }
}

locals {
  site_url = "https://${var.domain}"

  # env var the backend reads -> Secret Manager secret id
  app_secrets = {
    DB_PASSWORD             = google_secret_manager_secret.db_password.secret_id
    JWT_SECRET              = google_secret_manager_secret.jwt.secret_id
    SMTP_USERNAME           = "hr-smtp-username"
    SMTP_PASSWORD           = "hr-smtp-password"
    RAZORPAY_KEY_ID         = "hr-razorpay-key-id"
    RAZORPAY_KEY_SECRET     = "hr-razorpay-key-secret"
    RAZORPAY_WEBHOOK_SECRET = "hr-razorpay-webhook-secret"
  }

  # Public URLs use https://<domain>; the CORS origin must match what the browser sends
  app_env = merge({
    APP_CORS_ALLOWED_ORIGINS = local.site_url
    VERIFY_LINK_BASE         = "${local.site_url}/api/auth/verify-email"
    VERIFY_REDIRECT_BASE     = "${local.site_url}/verify-email.html"
    RESET_LINK_BASE          = "${local.site_url}/reset-password.html"
    INVITE_LINK_BASE         = "${local.site_url}/set-password.html"
    LOGIN_LINK_BASE          = "${local.site_url}/login.html"
    BILLING_PORTAL_LINK_BASE = "${local.site_url}/billing.html"
    RAZORPAY_ENABLED         = tostring(var.razorpay_enabled)
    MEDIA_BUCKET             = google_storage_bucket.media.name
    },
    var.smtp_from == "" ? {} : { SMTP_FROM = var.smtp_from },
  )
}

resource "google_secret_manager_secret_iam_member" "vm_app_secrets" {
  for_each = merge(
    { for k, s in google_secret_manager_secret.external : k => s.secret_id },
    { jwt = google_secret_manager_secret.jwt.secret_id },
  )

  project   = var.project
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.hr_server1.email}"
}
