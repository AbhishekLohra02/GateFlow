# terraform/bootstrap

Run **by a human, from AWS CloudShell, once**. Never by CI.

Creates the three things the pipeline depends on but must not control:

| Resource | Why bootstrap owns it |
|---|---|
| S3 state bucket | A stack that can delete the bucket holding its own state is one bad plan from unrecoverable. |
| GitHub OIDC provider | Trust anchor for every CI authentication. |
| `gateflow-github-actions` IAM role | **If CI's Terraform managed CI's own role, anyone who can merge a PR could grant that role more permissions.** Privilege escalation. |

Everything else - ECR, VPC, ECS - is CI-managed. That separation is the
point: bootstrap is the control plane, CI is the workload.

---

## Run it

### 1. Install Terraform in CloudShell

CloudShell resets everything outside `$HOME` between sessions, so install
into `~/bin`, which persists.

```bash
mkdir -p ~/bin && cd ~/bin
curl -sLo tf.zip https://releases.hashicorp.com/terraform/1.16.3/terraform_1.16.3_linux_amd64.zip
unzip -o tf.zip && rm tf.zip
echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc && export PATH=$HOME/bin:$PATH
terraform version
```

### 2. Apply, with local state

```bash
cd ~ && git clone https://github.com/AbhishekLohra02/GateFlow.git
cd GateFlow/terraform/bootstrap

terraform init     # no backend block yet -> state is local, on purpose
terraform plan     # READ THIS. ~8 resources to add, 0 to destroy.
terraform apply
```

Note the two outputs. You need both.

### 3. Move bootstrap's own state into the bucket it just made

This is the second half of the chicken-and-egg. The bucket now exists, so
state can live in it.

Create `backend.tf` here, substituting your account ID:

```hcl
terraform {
  backend "s3" {
    bucket       = "gateflow-tfstate-<ACCOUNT_ID>"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

Then:

```bash
terraform init -migrate-state    # answer "yes"
```

Terraform copies the local state up to S3. Confirm with `terraform plan` -
it must report **no changes**. If it wants to recreate the bucket, the
migration did not take; stop and fix it rather than applying.

`backend.tf` is safe to commit. The local `terraform.tfstate` left behind is
already covered by `.gitignore` - never commit it.

### 4. Wire the role into GitHub

GitHub -> Settings -> Secrets and variables -> Actions -> New repository secret:

- Name: `AWS_ROLE_ARN`
- Value: the `github_actions_role_arn` output

An ARN is an address, not a credential - it is safe in a public repo. What
makes it safe to expose is the `sub` condition in the trust policy, not
secrecy.

---

## Teardown

`prevent_destroy = true` on the bucket makes `terraform destroy` fail here
by design. That is not a bug to work around - it is the guard working.
Removing it is a deliberate, separate commit.
