# terraform/shared

Resources used by **every** environment, so they live in one stack with one
state file rather than being duplicated into dev/staging/prod.

Currently: the ECR repository.

## Why this is not under `environments/`

`environments/dev|staging|prod` each describe one deployment of the app.
This stack describes things that exist *once* and are consumed by all three.
Putting ECR in `environments/dev` would mean staging and prod depend on the
dev stack, and a `terraform destroy` in dev would take the registry - and
therefore every image prod is running - with it.

## The S3 bucket is deliberately not managed here

It was created by hand. Terraform cannot manage the bucket that stores its
own state without a circular dependency. See the comment in `backend.tf`.

## First run

```bash
terraform init      # downloads the AWS provider, connects to the S3 backend
terraform plan      # shows what WOULD change - always read this
terraform apply     # makes it real
```
