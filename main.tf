terraform {
  backend "gcs" {
    bucket = "terraform-hr-bucket"
    prefix = "terraform/state"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "google" {
  project = var.project
  region  = var.region
  zone    = var.zone
}

# Dedicated service account for the VM (hr-server1-sa@<project>.iam.gserviceaccount.com)
resource "google_service_account" "hr_server1" {
  account_id   = "hr-server1-sa"
  display_name = "HR server1 VM"
  project      = var.project

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "hr_server1_logging" {
  project = var.project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.hr_server1.email}"
}

resource "google_project_iam_member" "hr_server1_monitoring" {
  project = var.project
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.hr_server1.email}"
}

# Static external IP: stays the same across VM stop/start
resource "google_compute_address" "hr_server1_external_ip" {
  depends_on = [google_project_service.apis]

  name         = "hr-server1-external-ip"
  region       = var.region
  address_type = "EXTERNAL"
  labels       = var.labels
}

resource "google_compute_instance" "hr_server1" {
  # Hidden dependencies: the boot script reads the secret and the bucket
  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_version.db_password,
    google_secret_manager_secret_iam_member.vm_db_password,
    google_storage_bucket_iam_member.vm_war_reader,
    google_secret_manager_secret_iam_member.vm_app_secrets,
    google_secret_manager_secret_version.jwt,
  ]

  name         = "hr-server1"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["hr-web", "hr-ssh-iap"]
  labels       = var.labels

  deletion_protection = var.deletion_protection

  boot_disk {
    initialize_params {
      image = "projects/${var.project}/global/images/family/${var.image_family}"
      size  = var.disk_size_gb
      type  = "pd-standard" # free tier covers standard PD, not pd-balanced
    }
  }

  network_interface {
    network = "default"

    access_config {
      nat_ip = google_compute_address.hr_server1_external_ip.address
    }
  }

  service_account {
    email  = google_service_account.hr_server1.email
    scopes = ["cloud-platform"] # needed for Secret Manager; access is limited by the SA's IAM roles
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"

    startup-script = templatefile("${path.module}/deploy.sh.tftpl", {
      project   = var.project
      bucket    = google_storage_bucket.war_bucket.name
      db_secret = google_secret_manager_secret.db_password.secret_id
      secrets   = local.app_secrets
      env       = local.app_env
    })
  }

  allow_stopping_for_update = true
}

# HTTP/HTTPS to the web tier: anywhere until restrict_web_to_lb, then LB ranges only
resource "google_compute_firewall" "hr_allow_web" {
  depends_on = [google_project_service.apis]

  name    = "hr-allow-web"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = var.restrict_web_to_lb ? local.google_lb_ranges : ["0.0.0.0/0"]
  target_tags   = ["hr-web"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# SSH only through Identity-Aware Proxy (Google's IAP range)
resource "google_compute_firewall" "hr_allow_ssh_iap" {
  depends_on = [google_project_service.apis]

  name    = "hr-allow-ssh-iap"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["hr-ssh-iap"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Tomcat 8080: only from trusted CIDRs; no rule is created if the list is empty
resource "google_compute_firewall" "hr_allow_tomcat" {
  depends_on = [google_project_service.apis]

  count   = length(var.tomcat_allowed_cidrs) > 0 ? 1 : 0
  name    = "hr-allow-tomcat"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = var.tomcat_allowed_cidrs
  target_tags   = ["hr-web"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
