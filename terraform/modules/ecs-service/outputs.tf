output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS service name - what `aws ecs update-service` targets."
  value       = aws_ecs_service.app.name
}

output "task_definition_arn" {
  description = "ARN of the current task definition revision."
  value       = aws_ecs_task_definition.app.arn
}

output "log_group_name" {
  description = "CloudWatch log group holding container output."
  value       = aws_cloudwatch_log_group.app.name
}

output "autoscaling_group_name" {
  description = "Name of the ASG supplying container instances."
  value       = aws_autoscaling_group.this.name
}
