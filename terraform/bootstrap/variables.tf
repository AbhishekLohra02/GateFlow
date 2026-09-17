variable "aws_region" {
  description = "Region for the state bucket. Must match backend config elsewhere."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "owner/repo allowed to assume the CI role. The security boundary."
  type        = string
  default     = "AbhishekLohra02/GateFlow"

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "Must be in owner/repo form, e.g. AbhishekLohra02/GateFlow."
  }
}

# GitHub's OIDC token now carries IMMUTABLE identifiers: the owner and repo
# numeric IDs, which can never be re-registered by anyone else. Names can.
#
# Find them in a workflow's OIDC claims, or via:
#   curl -s https://api.github.com/repos/AbhishekLohra02/GateFlow | jq .id,.owner.id
variable "github_repository_owner_id" {
  description = "Numeric GitHub account ID of the repo owner."
  type        = string
  default     = "217813897"
}

variable "github_repository_id" {
  description = "Numeric GitHub repository ID."
  type        = string
  default     = "1374185994"
}
