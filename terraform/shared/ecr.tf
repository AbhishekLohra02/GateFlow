# The container registry. ONE repository, shared by dev/staging/prod.
#
# Why shared rather than one per environment: the entire point of a
# promotion pipeline is that the EXACT bytes tested in dev are what reach
# prod. Separate per-env repositories would mean copying (or worse,
# rebuilding) the image between environments - and a rebuilt image is a
# different artifact, so everything you proved in dev proves nothing about
# prod. Same image digest, promoted forward. That is the whole idea.
resource "aws_ecr_repository" "app" {
  name = var.ecr_repository_name

  # Tags cannot be overwritten once pushed.
  #
  # With MUTABLE (the default), someone can push a different image over an
  # existing tag. Now the SHA in your deploy logs points at code that is no
  # longer there, rollback targets silently change under you, and two
  # machines pulling "the same" tag can get different bytes. IMMUTABLE makes
  # that a hard error at push time instead of a mystery at 2am.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # Free, and catches a vulnerable base image that was clean when Trivy
    # scanned it in CI but had a CVE disclosed against it afterwards.
    scan_on_push = true
  }

  # Lets `terraform destroy` delete the repo even when it still holds
  # images. Without it, teardown fails with "repository contains images"
  # and you are deleting them by hand in the console.
  #
  # This is a DELIBERATE choice for an ephemeral learning account. On a real
  # production registry you would leave this false - it is exactly the
  # setting that turns a fat-fingered destroy into an outage with no images
  # left to roll back to.
  force_delete = true
}

# ECR free tier is 500MB TOTAL. Every merge to main pushes another image.
#
# At ~150MB per python:3.12-slim image that is roughly three pushes before
# you are over - and storage overage is one of the few things here that
# actually bills. Without a lifecycle policy this is a slow leak that
# surfaces as a surprise line item weeks later.
#
# Rules are evaluated in priority order, lowest number first, and each image
# is only ever acted on by the FIRST rule that matches it.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        # Untagged images are almost always garbage: layers orphaned when a
        # tag got replaced, or a failed push. Nothing can deploy them
        # because nothing can name them.
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        # Keep the last N tagged images. Rollback needs history, but it
        # needs the last few commits, not every commit ever.
        rulePriority = 2
        description  = "Keep only the ${var.image_retention_count} most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.image_retention_count
        }
        action = { type = "expire" }
      }
    ]
  })
}
