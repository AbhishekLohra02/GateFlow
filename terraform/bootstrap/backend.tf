# Added AFTER the first apply, deliberately.
#
# On run #1 this file did not exist, so Terraform used local state - it had
# to, because the bucket below did not exist yet. Now that bootstrap has
# created the bucket, its own state can live there like every other stack's.
#
# The move is done with `terraform init -migrate-state`, which uploads the
# local state file and switches the backend. That two-step is the standard
# resolution to the bootstrap circularity; there is no way to skip it.
terraform {
  backend "s3" {
    bucket = "gateflow-tfstate-355421126727"

    # Distinct key from every other stack. The key is the isolation
    # boundary: a destroy here cannot see resources it has no state for.
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
