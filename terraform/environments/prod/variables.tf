variable "aws_region" {
  description = "AWS region for this environment."
  type        = string
  default     = "us-east-1"
}

variable "image_tag" {
  description = "Image tag to deploy - the git commit SHA. Passed by CI."
  type        = string

  # Deliberately NO default.
  #
  # A default like "latest" would let a careless apply deploy something
  # nobody chose. Requiring it means every deployment names the exact commit
  # it is shipping, and an apply without one fails immediately instead of
  # silently doing the wrong thing.
}

variable "instance_type" {
  description = "EC2 instance type for container instances."
  type        = string
  default     = "t3.micro"
}

variable "desired_count" {
  description = "Number of task copies to run."
  type        = number
  default     = 2
}
