locals {
  name_prefix = "gateflow-prod"
  environment = "prod"
}

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

  # Distinct from dev (10.0.0.0/16) and staging (10.1.0.0/16).
  vpc_cidr = "10.2.0.0/16"
  app_port = 3000
}

module "app" {
  source = "../../modules/ecs-service"

  name_prefix = local.name_prefix
  environment = local.environment

  subnet_ids        = module.network.public_subnet_ids
  security_group_id = module.network.security_group_id

  # The exact image that passed dev AND staging. Same digest, promoted
  # forward - never rebuilt for production.
  image = "${data.terraform_remote_state.shared.outputs.ecr_repository_url}:${var.image_tag}"

  instance_type = var.instance_type

  # ---------------------------------------------------------------------
  # THIS IS WHERE PROD DIFFERS, AND IT IS NOT COSMETIC.
  #
  # Two instances, two tasks. Since the container binds a fixed host port,
  # one task per instance is the ceiling - so two tasks requires two
  # machines. That buys two things:
  #
  #   1. Survival of a single instance or availability-zone failure. The
  #      subnets already span two zones; with one instance that redundancy
  #      was theoretical.
  #   2. ZERO-DOWNTIME DEPLOYMENTS, below.
  # ---------------------------------------------------------------------
  instance_count = 2
  desired_count  = 2

  # Rolling deployment instead of stop-then-start.
  #
  # dev and staging run min_healthy = 0, meaning ECS may stop the only task
  # before starting its replacement - a few seconds of downtime on every
  # deploy, forced by having a single instance.
  #
  # At 50% with two tasks, ECS must keep one serving at all times: it drains
  # and replaces one, waits for it to pass its health check, then does the
  # other. Requests keep being served throughout.
  #
  # max_percent stays at 100 because there is no spare capacity to place a
  # third task on. With a load balancer and dynamic host ports this would be
  # 200 - start the new ones first, then drain the old - which is safer
  # again, because a failed new task never costs you capacity.
  deployment_min_healthy_percent = 50
  deployment_max_percent         = 100

  # Longer than dev (3) and staging (7). Production logs are what you have
  # during an incident review, and incidents are not always noticed the day
  # they happen. Still well inside the free tier at this volume.
  log_retention_days = 30
}
