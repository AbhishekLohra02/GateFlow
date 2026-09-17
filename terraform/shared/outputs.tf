# Outputs are this stack's published interface.
#
# Later stacks (dev/staging/prod) and the CI pipeline need the registry URL
# to tag and push images. Outputs mean they read it from state rather than
# having the account ID and region copy-pasted into a workflow file, where
# it rots the moment anything changes.
output "ecr_repository_url" {
  description = "Full ECR repo URI - what `docker tag` and `docker push` need."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the ECR repository, for scoping IAM policies later."
  value       = aws_ecr_repository.app.arn
}

output "ecr_registry" {
  description = "Registry host only - what `docker login` authenticates against."
  # The repository_url is <registry>/<repo>; strip the repo name off the end.
  value = split("/", aws_ecr_repository.app.repository_url)[0]
}
