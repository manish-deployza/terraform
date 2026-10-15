# GitHub -> Cloud Build -> WAR in GCS.
# Two-stage apply: the GitHub connection needs a PAT that lives only in Secret Manager.
#   1. apply with enable_github_connection = false (bucket, SA, secret shell)
#   2. add the PAT:  printf '%s' "$TOKEN" | gcloud secrets versions add hr-github-pat --data-file=- --project=<project>
#   3. set github_app_installation_id (repos are in var.github_repos), enable_github_connection = true and apply

locals {
  war_bucket_name = "${var.project}-war-bucket"
  github_enabled  = var.enable_github_connection ? 1 : 0
}

resource "google_storage_bucket" "war_bucket" {
  depends_on = [google_project_service.apis]

  name                        = local.war_bucket_name
  project                     = var.project
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = var.labels

  versioning {
    enabled = true
  }

  # Keep the last few WAR versions only
  lifecycle_rule {
    condition {
      num_newer_versions = 10
    }
    action {
      type = "Delete"
    }
  }
}

# Dedicated build identity (no default Cloud Build / compute SA)
resource "google_service_account" "cloudbuild" {
  account_id   = "hr-cloudbuild-sa"
  display_name = "HR Cloud Build WAR builder"
  project      = var.project

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "cloudbuild_logging" {
  project = var.project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloudbuild.email}"
}

resource "google_storage_bucket_iam_member" "cloudbuild_war_writer" {
  bucket = google_storage_bucket.war_bucket.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.cloudbuild.email}"
}

# Secret shell only: the PAT value is added out-of-band so it never enters code or state
resource "google_secret_manager_secret" "github_pat" {
  depends_on = [google_project_service.apis]

  secret_id = "hr-github-pat"
  project   = var.project
  labels    = var.labels

  replication {
    auto {}
  }
}

# The Cloud Build service agent reads the PAT when it creates the connection
resource "google_secret_manager_secret_iam_member" "cloudbuild_agent_pat" {
  project   = var.project
  secret_id = google_secret_manager_secret.github_pat.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:service-${google_project.this.number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
}

resource "google_cloudbuildv2_connection" "github" {
  count = local.github_enabled

  project  = var.project
  location = var.region
  name     = "hr-github"

  github_config {
    app_installation_id = var.github_app_installation_id

    authorizer_credential {
      oauth_token_secret_version = "${google_secret_manager_secret.github_pat.id}/versions/latest"
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.cloudbuild_agent_pat]
}

resource "google_cloudbuildv2_repository" "app" {
  for_each = var.enable_github_connection ? var.github_repos : {}

  project           = var.project
  location          = var.region
  name              = each.key
  parent_connection = google_cloudbuildv2_connection.github[0].name
  remote_uri        = each.value.uri
}

resource "google_cloudbuild_trigger" "build_war" {
  for_each = var.enable_github_connection ? var.github_repos : {}

  project         = var.project
  location        = var.region
  name            = "build-war-${each.key}"
  description     = "Build the ${each.key} WAR on push to ${each.value.branch} and upload it to ${local.war_bucket_name}"
  service_account = google_service_account.cloudbuild.id
  tags            = ["hr", "war"]

  repository_event_config {
    repository = google_cloudbuildv2_repository.app[each.key].id

    push {
      branch = "^${each.value.branch}$"
    }
  }

  build {
    timeout = "900s"

    step {
      id         = "build-war"
      name       = var.build_image
      dir        = each.value.dir
      entrypoint = "mvn"
      args       = ["-B", "clean", "package", "-DskipTests"]
    }

    artifacts {
      objects {
        location = "gs://${google_storage_bucket.war_bucket.name}/${each.key}/$SHORT_SHA/"
        paths    = ["${each.value.dir}/target/*.war"]
      }
    }

    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
  }

  depends_on = [google_storage_bucket_iam_member.cloudbuild_war_writer]
}
