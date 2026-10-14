output "hr_server1_public_ip" {
  value = google_compute_address.hr_server1_external_ip.address
}
