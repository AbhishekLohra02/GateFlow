# GateFlow — Architecture (living doc, fill in as we build)

## Pipeline flow
PR opened -> lint + unit tests + Docker build + Trivy scan -> (gate: PR checks must pass)
merge to main -> build+push image to ECR -> deploy to dev -> integration/smoke tests
-> (gate: dev tests must pass) -> promote to staging -> tests again
-> (gate: manual approval) -> deploy to prod (rolling/blue-green) -> smoke test
-> auto-rollback on failure

## Infra
- 1 EKS cluster, 3 namespaces (dev/staging/prod)
- Terraform: separate state per environment
- ECR for images, ap VPC, per-env IAM roles (least privilege)

## To fill in as we go
- Actual AWS account ID / region
- EKS cluster name
- ECR repo URI
- Diagram (add once k8s + terraform exist)
