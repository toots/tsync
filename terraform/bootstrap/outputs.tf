output "state_bucket" {
  description = "State bucket name — put this in backend.hcl."
  value       = aws_s3_bucket.state.id
}
