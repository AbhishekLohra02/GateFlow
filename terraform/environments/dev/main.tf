locals {
  name_prefix = "gateflow-dev"
  environment = "dev"
}

# ---------------------------------------------------------------------------
# Read the shared stack's outputs.
#
# The ECR repository lives in terraform/shared. Rather than hardcoding
# "355421126727.dkr.ecr.us-east-1.amazonaws.com/gateflow-app" here - in three
# environment stacks, where it rots the moment the account or region changes
# - this reads it from the shared stack's state.
#
# Note it is read-only. This stack can SEE shared's outputs; it cannot modify
# shared's resources. That is the correct coupling between stacks.
# ---------------------------------------------------------------------------
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "gateflow-tfstate-355421126727"
    key    = "shared/terraform.tfstate"
    region = "us-east-1"
  }
}

module "network" {
  source = "../../modules/network"

  name_prefix = local.name_prefix
  vpc_cidr    = "10.0.0.0/16"
  app_port    = 3000
}

module "app" {
  source = "../../modules/ecs-service"

  name_prefix = local.name_prefix
  environment = local.environment

  subnet_ids        = module.network.public_subnet_ids
  security_group_id = module.network.security_group_id

  # The exact artifact being deployed, by digest-stable tag.
  image = "${data.terraform_remote_state.shared.outputs.ecr_repository_url}:${var.image_tag}"

  instance_type = var.instance_type
  desired_count = var.desired_count

  # Dev is the cheapest environment and the most disposable. Short log
  # retention, minimal capacity.
  log_retention_days = 3
}
