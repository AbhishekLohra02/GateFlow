variable "aws_region" {
  description = "AWS region for all shared resources."
  type        = string
  default     = "us-east-1"
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository holding the GateFlow app image."
  type        = string
  default     = "gateflow-app"
}

variable "image_retention_count" {
  description = "How many tagged images to keep before the oldest are expired."
  type        = number
  default     = 10

  # Validation runs at plan time, so a bad value fails in seconds instead of
  # halfway through an apply with resources already created.
  validation {
    condition     = var.image_retention_count > 0 && var.image_retention_count <= 100
    error_message = "Keep between 1 and 100 images - ECR free tier is only 500MB."
  }
}
