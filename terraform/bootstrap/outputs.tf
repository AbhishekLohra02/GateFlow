output "state_bucket_name" {
  description = "Paste this into the backend block of every other stack."
  value       = aws_s3_bucket.state.bucket
}

output "github_actions_role_arn" {
  description = "Set as the AWS_ROLE_ARN secret in GitHub. An ARN is an address, not a credential."
  value       = aws_iam_role.github_actions.arn
}

output "account_id" {
  description = "AWS account ID this project is deployed into."
  value       = data.aws_caller_identity.current.account_id
}
