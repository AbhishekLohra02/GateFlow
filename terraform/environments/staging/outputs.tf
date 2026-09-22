output "cluster_name" {
  value = module.app.cluster_name
}

output "service_name" {
  value = module.app.service_name
}

output "log_group_name" {
  value = module.app.log_group_name
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "deployed_image" {
  description = "The exact image reference this environment is running."
  value       = "${data.terraform_remote_state.shared.outputs.ecr_repository_url}:${var.image_tag}"
}

# There is no load balancer, so there is no stable DNS name. The app is
# reached on the instance's public IP, which changes whenever the ASG
# replaces the instance. This command finds the current one.
output "how_to_reach_it" {
  description = "Command to find the current public IP."
  value       = "aws ec2 describe-instances --filters 'Name=tag:Name,Values=${local.name_prefix}-ecs-instance' 'Name=instance-state-name,Values=running' --query 'Reservations[].Instances[].PublicIpAddress' --output text"
}
