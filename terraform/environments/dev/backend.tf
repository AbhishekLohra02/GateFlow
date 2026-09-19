# Dev's OWN state file, at its own key in the shared bucket.
#
# This is the blast-radius boundary. A `terraform destroy` run here loads
# only environments/dev/terraform.tfstate, so it can only see dev's
# resources. Prod is not merely protected by convention - it is invisible
# to this stack.
terraform {
  backend "s3" {
    bucket       = "gateflow-tfstate-355421126727"
    key          = "environments/dev/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
