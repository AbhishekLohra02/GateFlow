# The Terraform state bucket - created here, consumed by every other stack.
#
# Globally unique naming: S3 bucket names are unique across ALL AWS accounts
# worldwide, so "gateflow-tfstate" was taken years ago. Suffixing the account
# ID guarantees uniqueness without inventing random strings, and makes the
# owner obvious from the name.
resource "aws_s3_bucket" "state" {
  bucket = "gateflow-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    # Hard stop. This bucket holds the state of every stack in the project,
    # including its own. Without this, one `terraform destroy` run in the
    # wrong directory deletes the record of everything Terraform owns and
    # leaves you deleting orphaned resources by hand in the console.
    #
    # prevent_destroy makes that a plan-time error instead of an outage.
    # Removing this line is a deliberate two-step act, which is the point.
    prevent_destroy = true
  }
}

# Keeps every version of the state file.
#
# State is Terraform's only record of what it owns. A truncated write or a
# bad apply mid-flight leaves Terraform believing resources do not exist -
# so it creates duplicates, and the originals become orphans nothing
# manages. Versioning turns that from a cleanup job into a rollback.
#
# Cannot be applied retroactively to objects already written, which is why
# it goes on before the first state file ever lands.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# State files hold resource attributes in plaintext - for many resource
# types that includes generated passwords, keys and tokens. Encrypt at rest
# by default so no future stack can write an unencrypted object here.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    # Reduces KMS request costs; harmless with AES256 and good habit.
    bucket_key_enabled = true
  }
}

# Belt and braces. Buckets are private by default now, but this makes the
# intent explicit and prevents anyone later attaching a public policy by
# accident. A world-readable state bucket is a full disclosure of your
# infrastructure - and of whatever secrets ended up in state.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Old state versions are small but unbounded - every apply writes one.
# Expire them after 90 days so the bucket does not grow forever, while
# keeping a long enough window to actually recover from a bad apply.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  # Terraform can race ahead of versioning being enabled; this makes the
  # dependency explicit rather than relying on luck in graph ordering.
  depends_on = [aws_s3_bucket_versioning.state]

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
