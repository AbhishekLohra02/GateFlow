# Modules declare which providers they NEED, never how to configure them.
#
# A `provider` block inside a module is a classic mistake: it makes the
# module impossible to reuse across regions or accounts, and Terraform can
# no longer reliably destroy resources when the module is removed. The root
# stack owns provider configuration; the module only states its requirement.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
