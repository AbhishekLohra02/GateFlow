variable "name_prefix" {
  description = "Prefix for every resource name, e.g. 'gateflow-dev'."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block, e.g. 10.0.0.0/16."
  }
}

variable "subnet_count" {
  description = "How many public subnets to create, one per availability zone."
  type        = number
  default     = 2

  # Two is the floor for anything that claims to be highly available: one
  # subnet means one AZ, and an AZ outage takes the whole service with it.
  # More than three wastes address space here for no benefit.
  validation {
    condition     = var.subnet_count >= 2 && var.subnet_count <= 3
    error_message = "subnet_count must be 2 or 3."
  }
}

variable "app_port" {
  description = "TCP port the application listens on inside the container."
  type        = number
  default     = 3000
}

variable "ingress_cidr" {
  description = "CIDR allowed to reach the app port. 0.0.0.0/0 is open to the internet."
  type        = string
  default     = "0.0.0.0/0"
}
