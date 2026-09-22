variable "name_prefix" {
  description = "Prefix for every resource name, e.g. 'gateflow-dev'."
  type        = string
}

variable "environment" {
  description = "Environment name: dev, staging or prod."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "subnet_ids" {
  description = "Public subnet IDs the container instances launch into."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group applied to the container instances."
  type        = string
}

variable "image" {
  description = "Full image reference including tag, e.g. <acct>.dkr.ecr.us-east-1.amazonaws.com/gateflow-app:<sha>."
  type        = string
}

variable "app_port" {
  description = "Port the application listens on."
  type        = number
  default     = 3000
}

variable "instance_type" {
  description = "EC2 instance type for container instances."
  type        = string
  default     = "t3.micro"
}

variable "desired_count" {
  description = "How many copies of the task to run."
  type        = number
  default     = 1
}

variable "task_cpu" {
  description = "CPU units reserved for the task. 1024 units = 1 vCPU."
  type        = number
  default     = 128
}

variable "task_memory" {
  description = "Hard memory limit in MiB. The container is killed if it exceeds this."
  type        = number
  default     = 256
}

variable "log_retention_days" {
  description = "How long to keep container logs."
  type        = number
  # Logs default to NEVER expiring, which quietly grows past the 5GB free
  # tier forever. 7 days is plenty for a pipeline that redeploys constantly.
  default = 7
}

variable "instance_count" {
  description = "How many EC2 container instances to run."
  type        = number
  default     = 1
}

variable "deployment_min_healthy_percent" {
  description = "Minimum percent of desired_count that must stay RUNNING during a deployment."
  type        = number

  # 0 is correct for a SINGLE instance holding a static host port: the old
  # task must stop before the new one can bind the same port, so a brief
  # outage is unavoidable. With two or more instances, 50 keeps half the
  # capacity serving while the other half is replaced - a real rolling
  # deployment with no downtime.
  default = 0
}

variable "deployment_max_percent" {
  description = "Maximum percent of desired_count that may be RUNNING during a deployment."
  type        = number

  # 100 means no surge capacity: ECS may not start extra tasks beyond
  # desired_count. Raising it to 200 would start replacements BEFORE
  # stopping the old ones - faster and safer, but it needs spare capacity
  # to place them on, which a fixed-size cluster does not have.
  default = 100
}
