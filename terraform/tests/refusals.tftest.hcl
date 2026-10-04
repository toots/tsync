# The refusals a store makes on its own inputs, planned on each store module
# directly against mocked providers.

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

run "s3_accepts_defaults" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name            = "files"
    bucket          = "a"
    lambda_zip      = "tests/stores.tftest.hcl"
    lambda_zip_hash = "hash"
  }
}

run "s3_refuses_domain_without_share" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name            = "files"
    bucket          = "a"
    lambda_zip      = "tests/stores.tftest.hcl"
    lambda_zip_hash = "hash"
    deploy_share    = false
    custom_domain   = "share.example.org"
  }

  expect_failures = [aws_iam_user.client]
}

run "s3_refuses_ceiling_above_scratch" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name            = "files"
    bucket          = "a"
    lambda_zip      = "tests/stores.tftest.hcl"
    lambda_zip_hash = "hash"
    max_share_bytes = 10737418240
  }

  expect_failures = [aws_iam_user.client]
}

run "s3_refuses_rule_expiring_requests" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name                  = "files"
    bucket                = "a"
    lambda_zip            = "tests/stores.tftest.hcl"
    lambda_zip_hash       = "hash"
    extra_lifecycle_rules = [{ id = "sweep", prefix = "tsync/gc-jobs/", expiration_days = 7 }]
  }

  expect_failures = [aws_iam_user.client]
}

run "s3_refuses_whole_bucket_restore_class" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name                  = "files"
    bucket                = "a"
    lambda_zip            = "tests/stores.tftest.hcl"
    lambda_zip_hash       = "hash"
    extra_lifecycle_rules = [{ id = "cold", transitions = [{ days = 30, storage_class = "DEEP_ARCHIVE" }] }]
  }

  expect_failures = [aws_iam_user.client]
}

run "s3_accepts_rule_outside_tsync" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name                  = "files"
    bucket                = "a"
    lambda_zip            = "tests/stores.tftest.hcl"
    lambda_zip_hash       = "hash"
    extra_lifecycle_rules = [{ id = "cold", prefix = "other/", expiration_days = 7, transitions = [{ days = 30, storage_class = "DEEP_ARCHIVE" }] }]
  }
}

run "s3_refuses_archive_restore_class" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name            = "files"
    bucket          = "a"
    lambda_zip      = "tests/stores.tftest.hcl"
    lambda_zip_hash = "hash"
    archive_domains = { Movies = { after_days = 30, storage_class = "DEEP_ARCHIVE" } }
  }

  expect_failures = [var.archive_domains]
}

run "s3_refuses_archive_of_store_prefix" {
  command = plan
  module { source = "./modules/store-s3" }

  variables {
    name            = "files"
    bucket          = "a"
    lambda_zip      = "tests/stores.tftest.hcl"
    lambda_zip_hash = "hash"
    archive_domains = { shares = { after_days = 30 } }
  }

  expect_failures = [var.archive_domains]
}

run "gcs_accepts_defaults" {
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
  }
}

run "gcs_refuses_domain_without_share" {
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
    custom_domain       = "share.example.org"
  }

  expect_failures = [google_service_account.client]
}

run "gcs_refuses_ceiling_above_memory" {
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
    max_share_bytes     = 2147483648
  }

  expect_failures = [google_service_account.client]
}

run "gcs_refuses_archive_on_adopted_bucket" {
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
    create_bucket       = false
    archive_domains     = { Movies = { after_days = 30 } }
  }

  expect_failures = [google_service_account.client]
}

run "gcs_refuses_long_name" {
  command = plan
  module { source = "./modules/store-gcs" }

  variables {
    name                = "a-name-that-is-too-long"
    bucket              = "a"
    project             = "project"
    location            = "US"
    function_region     = "us-central1"
    source_bucket       = "src"
    source_object       = "hash.zip"
    storage_agent_email = "agent@example.org"
  }

  expect_failures = [var.name]
}
