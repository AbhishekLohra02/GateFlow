locals {
  name_prefix = "gateflow-staging"
  environment = "staging"
}

# Read the shared stack's outputs to get the ECR repository URL.
#
# Read-only: this stack can SEE shared's outputs but cannot modify shared's
# resources. That is the correct coupling between stacks - a dependency, not
# a shared owner.
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

  # A DIFFERENT address range from dev (10.0.0.0/16) and prod (10.2.0.0/16).
  #
  # Nothing today forces this - the VPCs are isolated and could all use the
  # same range. But identical ranges make future VPC peering impossible
  # (overlapping CIDRs cannot be routed between) and make flow logs
  # ambiguous, since 10.0.1.42 would exist in three places. Environments
  # are given distinct ranges from the start because retrofitting it means
  # rebuilding the network.
  vpc_cidr = "10.1.0.0/16"
  app_port = 3000
}

module "app" {
  source = "../../modules/ecs-service"

  name_prefix = local.name_prefix
  environment = local.environment

  subnet_ids        = module.network.public_subnet_ids
  security_group_id = module.network.security_group_id

  # The SAME image the dev deployment tested. Not rebuilt - promoted.
  # CI passes the identical commit SHA to every environment, which is what
  # makes testing in dev mean anything about staging.
  image = "${data.terraform_remote_state.shared.outputs.ecr_repository_url}:${var.image_tag}"

  instance_type = var.instance_type
  desired_count = var.desired_count

  # Staging mirrors dev's single-instance shape, so it inherits the same
  # brief outage on deploy. Keeping it identical to dev is deliberate: its
  # job is to rehearse the promotion path, not the production topology.
  log_retention_days = 7
}
