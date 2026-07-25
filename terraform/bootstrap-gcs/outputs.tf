output "state_bucket" {
  description = "State bucket name — put this in backend.hcl (bucket)."
  value       = google_storage_bucket.state.name
}
