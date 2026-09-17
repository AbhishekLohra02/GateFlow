# Pins BOTH the Terraform CLI and the provider.
#
# Why pin: `terraform apply` with an unpinned provider means CI can silently
# pull a new major version overnight and change what your config means. The
# classic failure is a provider upgrade that renames or re-defaults an
# argument - your plan suddenly wants to destroy and recreate resources
# nobody touched.
#
# "~> 6.0" is the pessimistic constraint operator: allow 6.1, 6.2, 6.99 -
# never 7.0. Minor versions are additive and safe; major versions are where
# breaking changes are allowed to live.
#
# required_version >= 1.10 is not arbitrary: S3 native state locking
# (use_lockfile, see backend.tf) was introduced in 1.10.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Applied to every resource this provider creates, automatically.
  #
  # Untagged AWS resources are how accounts rot: six months on, nobody can
  # tell what created a security group or whether deleting it breaks prod.
  # Doing it here rather than per-resource means it cannot be forgotten.
  default_tags {
    tags = {
      Project     = "GateFlow"
      ManagedBy   = "Terraform"
      Environment = "shared"
    }
  }
}
