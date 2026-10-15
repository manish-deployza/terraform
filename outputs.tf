output "hr_server1_public_ip" {
  value = google_compute_address.hr_server1_external_ip.address
}

output "war_bucket" {
  description = "GCS bucket receiving built WAR files (under <repo>/<short-sha>/)."
  value       = google_storage_bucket.war_bucket.url
}

output "lb_ip" {
  description = "Load balancer IP; point the domain's DNS A record here."
  value       = google_compute_global_address.lb_ip.address
}

output "recaptcha_site_key" {
  description = "reCAPTCHA Enterprise site key for the hr-ui widget."
  value       = google_recaptcha_enterprise_key.hr_web.name
}
