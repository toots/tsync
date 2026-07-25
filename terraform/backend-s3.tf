# Remote state in S3 (bucket created by ./bootstrap-s3). Bucket + region are
# supplied at init time to keep them out of source:
#
#   terraform init -backend-config=backend.hcl
#
# This is the default. For GCS-hosted state instead, see backend-gcs.tf.example
# (a config may have only one backend block).
#
terraform {
  backend "s3" {
    key          = "tsync/terraform.tfstate"
    encrypt      = true
    use_lockfile = true # S3-native locking; needs Terraform >= 1.10
  }
}
