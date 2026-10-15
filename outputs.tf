output "hr_server1_public_ip" {
  value = google_compute_address.hr_server1_external_ip.address
}

output "war_bucket" {
  description = "GCS bucket receiving built WAR files (under <repo>/<short-sha>/)."
  value       = google_storage_bucket.war_bucket.url
}
