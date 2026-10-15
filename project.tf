# Provider, region and zone are configured in main.tf / variables.tf.

variable "project_name" {
  description = "Display name of the project."
  type        = string
  default     = "HR Deployment"
}

variable "org_id" {
  description = "GCP organization ID. Set either org_id or folder_id."
  type        = string
  default     = null
}

variable "folder_id" {
  description = "GCP folder ID. Set either org_id or folder_id."
  type        = string
  default     = null
}

variable "billing_account" {
  description = "Billing account ID to attach to the project."
  type        = string
  default     = null
}

variable "apis" {
  description = "APIs to enable on the project."
  type        = list(string)
  default = [
    "compute.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "cloudbuild.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ]
}

variable "labels" {
  description = "Labels applied to the project."
  type        = map(string)
  default = {
    app = "hr"
    env = "prod"
  }
}

resource "google_project" "this" {
  project_id          = var.project
  name                = var.project_name
  org_id              = var.folder_id == null ? var.org_id : null
  folder_id           = var.folder_id
  billing_account     = var.billing_account
  labels              = var.labels
  auto_create_network = true # main.tf uses the "default" network
}

resource "google_project_service" "apis" {
  for_each = toset(var.apis)

  project            = google_project.this.project_id
  service            = each.value
  disable_on_destroy = false
}

output "project_id" {
  value = google_project.this.project_id
}

output "project_number" {
  value = google_project.this.number
}
