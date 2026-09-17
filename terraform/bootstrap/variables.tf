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
