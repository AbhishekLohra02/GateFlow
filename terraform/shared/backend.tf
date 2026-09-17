# WHERE TERRAFORM KEEPS ITS STATE.
#
# State is Terraform's record of which real AWS resources it owns and what
# their attributes were last time it looked. It is how `plan` can tell the
# difference between "create this" and "this already exists, leave it".
#
# Local state (the default) breaks the moment CI is involved: the GitHub
# Actions runner is destroyed after every job, so it starts with no state,
# concludes nothing exists, and tries to create a second copy of everything.
#
# NOTE THE BUCKET IS NOT MANAGED BY TERRAFORM. It was created by hand, on
# purpose. If Terraform created the bucket that stores its own state, the
# record of the bucket would live inside the bucket it just made - and
# destroying the stack would delete the state describing how to destroy it.
# Every real setup bootstraps the backend out-of-band exactly like this.
terraform {
  backend "s3" {
    # EDIT THIS LINE: append your 12-digit AWS account ID.
    #
    # These values are hardcoded because backend blocks CANNOT use
    # variables, locals, or any expression - they are read before Terraform
    # evaluates anything else, so there is nothing to interpolate from yet.
    # This surprises everyone once. The escape hatch for real multi-env
    # setups is partial configuration: omit the key here and pass
    # `-backend-config=key=...` at init time.
    bucket = "gateflow-tfstate-355421126727"

    # The path to THIS stack's state file inside the bucket. Every stack
    # gets its own key. That is what keeps dev, staging, prod and shared
    # isolated - a `destroy` here physically cannot see another stack's
    # resources, because it cannot see their state.
    key    = "shared/terraform.tfstate"
    region = "us-east-1"

    # Locking, via S3 conditional writes (Terraform >= 1.10).
    #
    # Two applies running at once - CI and you in CloudShell - can
    # interleave writes and produce a state file describing a reality that
    # never existed. The lock makes the second one wait.
    #
    # This used to require a separate DynamoDB table (`dynamodb_table`).
    # As of Terraform 1.10 S3 does it natively and the DynamoDB argument is
    # deprecated. Worth knowing both: you will meet the DynamoDB form in
    # every tutorial written before 2025 and in most existing codebases.
    use_lockfile = true

    encrypt = true
  }
}
