# Site shares (11 §7, §8): the sites bucket and the sites domain, planned on each
# store module directly against mocked providers.

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
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/mock"
    }
  }
  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      execution_arn = "arn:aws:execute-api:us-east-1:123456789012:mock"
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

run "s3_refuses_sites_bucket_without_domain" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name            = "files"
    bucket          = "a"
    lambda_zip      = "tests/stores.tftest.hcl"
    lambda_zip_hash = "hash"
    sites_bucket    = "a-sites"
  }

  expect_failures = [aws_iam_user.client]
}

run "s3_refuses_sites_domain_without_bucket" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name            = "files"
    bucket          = "a"
    lambda_zip      = "tests/stores.tftest.hcl"
    lambda_zip_hash = "hash"
    sites_domain    = "sites.example.org"
  }

  expect_failures = [aws_iam_user.client]
}

run "s3_refuses_sites_bucket_without_share" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name            = "files"
    bucket          = "a"
    lambda_zip      = "tests/stores.tftest.hcl"
    lambda_zip_hash = "hash"
    deploy_share    = false
    sites_bucket    = "a-sites"
    sites_domain    = "sites.example.org"
  }

  expect_failures = [aws_iam_user.client]
}

run "s3_refuses_dotted_sites_bucket" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name            = "files"
    bucket          = "a"
    lambda_zip      = "tests/stores.tftest.hcl"
    lambda_zip_hash = "hash"
    sites_bucket    = "a.sites"
    sites_domain    = "sites.example.org"
  }

  expect_failures = [aws_iam_user.client]
}

run "s3_refuses_sites_domain_equal_to_custom_domain" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name            = "files"
    bucket          = "a"
    lambda_zip      = "tests/stores.tftest.hcl"
    lambda_zip_hash = "hash"
    sites_bucket    = "a-sites"
    sites_domain    = "share.example.org"
    custom_domain   = "share.example.org"
  }

  expect_failures = [aws_iam_user.client]
}

run "gcs_refuses_sites_bucket_without_domain" {
  command = plan
  module { source = "./modules/store-gcs" }

  variables {
    name                = "media"
    bucket              = "a"
    project             = "project"
    location            = "US"
    function_region     = "us-central1"
    source_bucket       = "src"
    source_object       = "hash.zip"
    storage_agent_email = "agent@example.org"
    sites_bucket        = "a-sites"
  }

  expect_failures = [google_service_account.client]
}

run "gcs_refuses_sites_domain_without_bucket" {
  command = plan
  module { source = "./modules/store-gcs" }

  variables {
    name                = "media"
    bucket              = "a"
    project             = "project"
    location            = "US"
    function_region     = "us-central1"
    source_bucket       = "src"
    source_object       = "hash.zip"
    storage_agent_email = "agent@example.org"
    sites_domain        = "sites.example.org"
  }

  expect_failures = [google_service_account.client]
}

run "gcs_refuses_sites_bucket_without_share" {
  command = plan
  module { source = "./modules/store-gcs" }

  variables {
    name                = "media"
    bucket              = "a"
    project             = "project"
    location            = "US"
    function_region     = "us-central1"
    source_bucket       = "src"
    source_object       = "hash.zip"
    storage_agent_email = "agent@example.org"
    deploy_share        = false
    sites_bucket        = "a-sites"
    sites_domain        = "sites.example.org"
  }

  expect_failures = [google_service_account.client]
}

run "gcs_refuses_dotted_sites_bucket" {
  command = plan
  module { source = "./modules/store-gcs" }

  variables {
    name                = "media"
    bucket              = "a"
    project             = "project"
    location            = "US"
    function_region     = "us-central1"
    source_bucket       = "src"
    source_object       = "hash.zip"
    storage_agent_email = "agent@example.org"
    sites_bucket        = "a.sites"
    sites_domain        = "sites.example.org"
  }

  expect_failures = [google_service_account.client]
}

run "gcs_refuses_sites_domain_equal_to_custom_domain" {
  command = plan
  module { source = "./modules/store-gcs" }

  variables {
    name                = "media"
    bucket              = "a"
    project             = "project"
    location            = "US"
    function_region     = "us-central1"
    source_bucket       = "src"
    source_object       = "hash.zip"
    storage_agent_email = "agent@example.org"
    sites_bucket        = "a-sites"
    sites_domain        = "share.example.org"
    custom_domain       = "share.example.org"
  }

  expect_failures = [google_service_account.client]
}

run "s3_accepts_a_sites_bucket" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name            = "files"
    bucket          = "a"
    lambda_zip      = "tests/stores.tftest.hcl"
    lambda_zip_hash = "hash"
    sites_bucket    = "a-sites"
    sites_domain    = "sites.example.org"
  }

  assert {
    condition     = length(aws_s3_bucket.sites) == 1 && length(aws_scheduler_schedule.site_sweep) == 1
    error_message = "a sites bucket and its sweep are planned"
  }
  assert {
    condition     = aws_lambda_function.share[0].environment[0].variables.SITES_DOMAIN == "sites.example.org"
    error_message = "the share function is told its sites domain"
  }
  assert {
    condition     = length(aws_apigatewayv2_api.share) == 1 && length(aws_apigatewayv2_domain_name.sites) == 1
    error_message = "the API fronts the sites domain without a custom domain"
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.sites[0].block_public_acls && !aws_s3_bucket_public_access_block.sites[0].block_public_policy
    error_message = "ACLs stay blocked; only the bucket policy grants public reads"
  }
}

run "gcs_accepts_a_sites_bucket" {
  command = plan
  module { source = "./modules/store-gcs" }

  variables {
    name                = "media"
    bucket              = "a"
    project             = "project"
    location            = "US"
    function_region     = "us-central1"
    source_bucket       = "src"
    source_object       = "hash.zip"
    storage_agent_email = "agent@example.org"
    sites_bucket        = "a-sites"
    sites_domain        = "sites.example.org"
  }

  assert {
    condition     = google_storage_bucket_iam_member.sites_public[0].role == "roles/storage.legacyObjectReader"
    error_message = "the public reads objects and never lists"
  }
  assert {
    condition     = google_cloudfunctions2_function.share[0].service_config[0].environment_variables.SITES_BUCKET == "a-sites"
    error_message = "the share function is told its sites bucket"
  }
  assert {
    condition     = google_cloud_run_domain_mapping.sites[0].name == "sites.example.org"
    error_message = "the sites domain maps onto the share function"
  }
}

run "s3_without_sites_plans_none" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name            = "files"
    bucket          = "a"
    lambda_zip      = "tests/stores.tftest.hcl"
    lambda_zip_hash = "hash"
  }

  assert {
    condition     = length(aws_s3_bucket.sites) == 0 && length(aws_apigatewayv2_api.share) == 0
    error_message = "no sites bucket and no API without a domain"
  }
  assert {
    condition     = !contains(keys(aws_lambda_function.share[0].environment[0].variables), "SITES_BUCKET")
    error_message = "a store without a sites bucket tells its function none"
  }
}
