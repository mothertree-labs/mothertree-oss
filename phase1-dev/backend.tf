terraform {
  required_version = ">= 1.11"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }

  # Remote state on Linode Object Storage (S3-compatible).
  #
  # Bucket and scoped access key are created by the operator before first init —
  # see ./MIGRATION.md. Credentials are picked up from the environment as
  # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (Terraform requires the AWS_ names
  # even for non-AWS S3 backends).
  #
  # use_lockfile = true enables native S3 conditional-write locking (requires
  # Terraform >= 1.11) so we don't need a separate DynamoDB-style lock store.
  backend "s3" {
    bucket = "mothertree-tf-state-dev"
    key    = "phase1-dev/terraform.tfstate"
    region = "us-east-1" # required by validator; Linode ignores it

    endpoints = {
      s3 = "https://us-lax-1.linodeobjects.com"
    }

    use_path_style              = true
    use_lockfile                = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
  }
}
