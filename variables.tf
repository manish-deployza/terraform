variable "project" {
  description = "ID of the new GCP project created by project.tf (globally unique)"
  type        = string
  default     = "hr-deployment-prod"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project))
    error_message = "Project ID must be 6-30 chars: lowercase letters, digits, hyphens; start with a letter; not end with a hyphen."
  }
}

variable "region" {
  description = "GCP region (Always Free e2-micro region: us-central1, us-east1 or us-west1)"
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "Region must look like us-central1."
  }
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "us-central1-a"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+-[a-z]$", var.zone))
    error_message = "Zone must look like us-central1-a."
  }
}

variable "machine_type" {
  description = "VM machine type"
  type        = string
  default     = "e2-micro"
}

variable "tomcat_allowed_cidrs" {
  description = "CIDRs allowed to reach Tomcat on 8080 (e.g. [\"203.0.113.5/32\"]). Empty = closed; use nginx on 80/443 instead."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.tomcat_allowed_cidrs : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    error_message = "Each entry must be a valid IPv4 CIDR such as 203.0.113.5/32, and 0.0.0.0/0 is not allowed."
  }
}

variable "disk_size_gb" {
  description = "Boot disk size in GB"
  type        = number
  default     = 30

  validation {
    condition     = var.disk_size_gb >= 10 && var.disk_size_gb <= 30
    error_message = "Disk must be 10-30 GB to stay in the free tier (and at least the image size)."
  }
}

variable "image_family" {
  description = "Custom image family built by Packer (vm_images/)"
  type        = string
  default     = "hr-ubuntu-stack"
}

variable "deletion_protection" {
  description = "Protect the VM from accidental deletion (terraform destroy and API deletes fail while true)"
  type        = bool
  default     = true
}

variable "enable_github_connection" {
  description = "Create the GitHub connection, repository link and trigger. Set true only after the PAT is stored in the hr-github-pat secret."
  type        = bool
  default     = false
}

variable "github_app_installation_id" {
  description = "Installation ID of the Cloud Build GitHub App on the GitHub account/org (number in github.com/settings/installations/<id>)."
  type        = number
  default     = null
}

variable "github_repos" {
  description = "Repos to build into WAR files, keyed by short name (used in trigger and bucket path)."
  type = map(object({
    uri    = string
    branch = optional(string, "main")
    dir    = optional(string, ".") # folder holding pom.xml, relative to the repo root
  }))
  default = {
    hr-server = { uri = "https://github.com/manish-deployza/hr-server.git", dir = "backend" }
    hr-ui     = { uri = "https://github.com/manish-deployza/hr-ui.git" }
  }

  validation {
    condition     = alltrue([for r in var.github_repos : can(regex("^https://github\\.com/[^/]+/[^/]+\\.git$", r.uri))])
    error_message = "Each uri must look like https://github.com/<owner>/<repo>.git."
  }
}

variable "build_image" {
  description = "Builder image with Maven and a JDK matching the VM's Java (21)."
  type        = string
  default     = "maven:3-eclipse-temurin-21"
}

variable "domain" {
  description = "Public domain for the HR site (e.g. hr.example.com). Its DNS A record must point at the lb_ip output."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain))
    error_message = "Must be a lowercase fully qualified domain such as hr.example.com."
  }
}

variable "restrict_web_to_lb" {
  description = "When true, ports 80/443 on the VM accept traffic only from the load balancer ranges. Enable after the LB is verified."
  type        = bool
  default     = false
}

variable "external_secret_ids" {
  description = "Secret Manager secrets created empty for third-party credentials (Mailjet, Razorpay). Values are added out-of-band."
  type        = list(string)
  default = [
    "hr-smtp-username",
    "hr-smtp-password",
    "hr-razorpay-key-id",
    "hr-razorpay-key-secret",
    "hr-razorpay-webhook-secret",
  ]
}

variable "smtp_from" {
  description = "Validated sender address on the Mailjet account (empty = not set)."
  type        = string
  default     = ""
}

variable "razorpay_enabled" {
  description = "Turn on live Razorpay billing. Leave false until the Razorpay secrets have values."
  type        = bool
  default     = false
}
