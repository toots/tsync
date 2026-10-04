# The function package: the runtime files of lambda/, and nothing the working
# tree happens to hold beside them. Every configuration that deploys a function
# builds it here.

terraform {
  required_providers {
    archive = { source = "hashicorp/archive", version = ">= 2.5" }
  }
}

data "archive_file" "package" {
  type        = "zip"
  source_dir  = "${path.module}/../../../lambda"
  output_path = "${path.root}/build/lambda.zip"
  excludes = [
    "test_*.py",
    "vendor/README.md",
    "**/__pycache__/**",
    ".pytest_cache/**",
    ".venv/**",
  ]
}

output "path" {
  description = "Path of the package zip."
  value       = data.archive_file.package.output_path
}

output "base64sha256" {
  description = "Base64 SHA-256 of the zip, as Lambda compares it."
  value       = data.archive_file.package.output_base64sha256
}

output "sha256" {
  description = "Hex SHA-256 of the zip."
  value       = data.archive_file.package.output_sha256
}
