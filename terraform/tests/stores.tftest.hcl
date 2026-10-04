# Plans against mocked providers: no account, no credentials. What is checked is
# what the configuration accepts and refuses before anything is applied
# (docs/spec/11-infrastructure.md, Conformance).

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }
  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:123456789012:function:mock"
    }
  }
  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::mock"
    }
  }
  mock_data "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::mock"
    }
  }
}

mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/project/serviceAccounts/tsync-mock@project.iam.gserviceaccount.com"
      email = "tsync-mock@project.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_service_account_key" {
    defaults = {
      private_key = "e30="
    }
  }
}

variables {
  region      = "us-east-1"
  gcp_project = "project"
  gcp_region  = "US"
}

run "both_providers" {
  command = plan

  variables {
    stores = {
      files = {
        bucket          = "files"
        archive_domains = { "My Domain" = { after_days = 30 } }
      }
      bare = {
        bucket        = "bare"
        create_bucket = false
        share         = false
        region        = "eu-west-1"
      }
    }
    gcs_stores = {
      media = { bucket = "media", custom_domain = "share.example.org" }
    }
  }

  assert {
    condition     = output.stores["files"].type == "s3" && output.stores["media"].type == "gcs"
    error_message = "Every store is reported with its backend type."
  }
  assert {
    condition     = !contains(keys(output.stores["bare"]), "shareUrl")
    error_message = "A store without a share function reports no shareUrl."
  }
  assert {
    condition     = keys(output.custom_domain_dns) == ["media"]
    error_message = "Only stores with a custom domain report DNS records."
  }
}

run "one_provider_only" {
  command = plan

  variables {
    region     = null
    gcs_stores = { media = { bucket = "media" } }
  }

  assert {
    condition     = keys(output.stores) == ["media"]
    error_message = "A GCS-only deployment plans with no AWS input."
  }
}

run "refuses_duplicate_name" {
  command = plan

  variables {
    stores     = { files = { bucket = "a" } }
    gcs_stores = { files = { bucket = "b" } }
  }

  expect_failures = [terraform_data.store_names]
}
