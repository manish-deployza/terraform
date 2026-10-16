# Private bucket for user uploads: profile photos, CSV/TSV imports and other media.
# Browsers never get public URLs; the backend reads/writes with the VM service account
# and can hand out short-lived signed URLs.
resource "google_storage_bucket" "media" {
  depends_on = [google_project_service.apis]

  name                        = "${var.project}-media-bucket"
  project                     = var.project
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false # refuse to delete a bucket that still holds user data
  labels                      = var.labels

  # Recover from accidental overwrite/delete; old versions age out so storage stays small
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 30
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  # Direct browser uploads/downloads via signed URLs from the site only
  cors {
    origin          = [local.site_url]
    method          = ["GET", "PUT", "HEAD"]
    response_header = ["Content-Type"]
    max_age_seconds = 3600
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket_iam_member" "vm_media_rw" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectUser" # read/write/delete objects, no bucket admin
  member = "serviceAccount:${google_service_account.hr_server1.email}"
}

# Lets the backend sign URLs without a key file (VM service account signs as itself)
resource "google_service_account_iam_member" "vm_sign_own_urls" {
  service_account_id = google_service_account.hr_server1.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.hr_server1.email}"
}
