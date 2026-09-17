terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # NOTE: there is deliberately no `backend` block here on the first run.
  #
  # This stack creates the state bucket. On run #1 it cannot store its state
  # in a bucket that does not exist yet, so it starts with local state and
  # is migrated afterwards - see README.md. That is the whole chicken-and-egg
  # problem, resolved in two steps rather than hand-waved away.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "GateFlow"
      ManagedBy = "Terraform"
      Stack     = "bootstrap"
    }
  }
}

# Reads the account ID of whoever is running this, rather than hardcoding it.
# Data sources read existing facts; resources create things.
data "aws_caller_identity" "current" {}
