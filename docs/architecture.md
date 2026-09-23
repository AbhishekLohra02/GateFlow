# GateFlow — Architecture

GateFlow is built in two phases. Phase 1 ships the app to AWS with no
Kubernetes; Phase 2 migrates the same app and the same pipeline onto
Kubernetes. The split is deliberate: EKS is the only component in the
design with no AWS free tier at all ($0.10/hr, always), so deferring it
keeps Phase 1 at genuinely $0 while still exercising real cloud infra.

---

## Phase 1 — Terraform + ECS on EC2 (no Kubernetes)

### What it looks like

```
 GitHub (public repo)
   │
PR opened -> Docker build + container verification + Trivy scan + terraform plan -> (gate: PR checks must pass)
   │                (nothing merges unless all pass)
   │
   └─ merge to main
        │
        ├─► build image, tag with git SHA ──► push to ECR
        │
        ├─► terraform apply (dev)    ──► ECS service updates ──► smoke test
        ├─► terraform apply (staging)──► ECS service updates ──► smoke test
        ├─► ⏸  MANUAL APPROVAL GATE  (GitHub Environments, required reviewer)
        └─► terraform apply (prod)   ──► ECS service updates ──► smoke test
                        ECS deployment circuit breaker reverts a deployment
                        that never reaches steady state. Reverting a deploy
                        that succeeds and THEN fails its smoke test is not
                        yet implemented.
```

### AWS resources, per environment

Each of dev / staging / prod is an independent Terraform stack with its
own state file, so a `destroy` in one can never reach another.

```
VPC (free)
 └─ public subnet (free)          ← public on purpose: see "Cost decisions"
     └─ EC2 t3.micro (free tier)  ← runs the ECS agent
         └─ ECS service
             └─ ECS task = the Flask container pulled from ECR
Security group (free)  ── allows :3000 inbound
CloudWatch log group   ── container stdout/stderr (5GB/mo free)
```

Shared across environments:
- **ECR** — one repository, images tagged by git SHA
- **S3 bucket** — Terraform remote state
- **State locking** — S3 native conditional writes (no separate lock table)

### Why each piece is what it is

**ECS on EC2, not Fargate.** ECS orchestration itself is free on either
launch type — AWS charges nothing for the control plane. But Fargate bills
per vCPU-second with no free tier, while EC2 `t3.micro` is free-tier
covered. Same orchestration, zero cost.

**ECS, not plain Docker on an EC2 box.** Running `docker run` over SSH
would be simpler and would teach nothing transferable. ECS gives real
orchestration primitives — desired count, health checks, rolling
replacement, rollback — and they map almost one-to-one onto the
Kubernetes objects in Phase 2 (task definition → pod spec, service →
deployment, desired count → replicas).

**Remote state in S3, not local `terraform.tfstate`.** State is Terraform's
record of what it owns. Local state means it lives on one laptop: CI can't
read it, nobody else can apply, and losing the file orphans every resource
Terraform created. S3 makes it shared, versioned and encrypted.

Locking uses S3's own conditional writes (`use_lockfile`, Terraform >= 1.10)
so two concurrent applies cannot interleave and corrupt the state. Every
guide written before 2025 pairs S3 with a DynamoDB table for this; that
approach is now deprecated and **no lock table exists in this project**.

**Immutable image tags (git SHA), never `:latest`.** With `:latest` you
cannot tell which commit is running in prod, and a rollback has nothing to
roll back *to* — the tag has already moved. Tagging by commit SHA makes
every deploy traceable and rollback a one-line tag change.

**GitHub OIDC, not AWS access keys in secrets.** The pipeline authenticates
to AWS by exchanging a short-lived GitHub identity token for temporary STS
credentials. Long-lived `AWS_ACCESS_KEY_ID` secrets are the single most
common way cloud credentials leak out of CI, and they never expire on
their own. OIDC credentials last minutes and cannot be reused.

**The CI role cannot escalate itself.** It began as `AdministratorAccess` -
deliberately, because scoping IAM before you know which API calls Terraform
actually makes is guesswork that costs hours in `AccessDenied` errors that
name an action but never a resource. It has since been narrowed to the
services this project uses, with IAM access bounded to roles named
`gateflow-*`.

The part that makes that a real boundary rather than a naming convention is
an explicit **Deny** on the pipeline's own role, the OIDC provider, and
destructive operations on the state bucket. Without it, "roles named
gateflow-*" would include `gateflow-github-actions` itself - so a merged
pull request could attach `AdministratorAccess` back onto it. An explicit
Deny beats any Allow in IAM, whatever else is attached.

`iam:PassRole` is separately constrained by `iam:PassedToService`. Passing a
role to a service is the usual route to privilege escalation: unrestricted,
the pipeline could start an ECS task running as an administrator role and
read whatever that role can read.

### Cost decisions (and what they trade away)

Two choices here are deliberately *not* production-correct. They are the
difference between $0 and roughly $50/month.

| Choice | Why | What it costs in realism |
|---|---|---|
| Public subnets, **no NAT Gateway** | NAT is ~$0.045/hr ≈ $33/mo and is never free | Real workloads put app instances in private subnets and egress via NAT. Ours are directly internet-reachable. |
| **No ALB/Ingress** — reach the task on the instance port | ALB is ~$16/mo | No TLS termination, no path routing, no health-check-based traffic shifting, no stable DNS name. |

Also avoided: EKS (never free), Fargate (no free tier), Elastic IPs left
unattached, and any public IPv4 beyond the free-tier 750 hrs/month.

---

## Phase 2 — Kubernetes (planned)

Same app, same pipeline shape, different runtime. `kind` (Kubernetes in
Docker) runs free inside a Codespace and inside GitHub Actions runners, so
the whole of Phase 2 can be free too. The ECS task definitions written in
Phase 1 become Deployments; `k8s/base` + `k8s/overlays/{dev,staging,prod}`
replace the per-environment Terraform variables for anything that is a
runtime concern rather than an infrastructure concern.

An optional short, time-boxed EKS run can prove the manifests work on a
real managed cluster — roughly $0.30 for two hours, destroyed the same
session.

---

## Concrete values (Phase 1)

| | |
|---|---|
| AWS account | `355421126727` |
| Region | `us-east-1` |
| ECR repository | `355421126727.dkr.ecr.us-east-1.amazonaws.com/gateflow-app` |
| Terraform state bucket | `gateflow-tfstate-355421126727` |
| CI role | `arn:aws:iam::355421126727:role/gateflow-github-actions` |

State layout inside the bucket - one key per stack, which is what makes a
`destroy` in one environment unable to see another's resources:

```
gateflow-tfstate-355421126727/
  bootstrap/terraform.tfstate     state bucket, OIDC provider, CI role
  shared/terraform.tfstate        ECR
  environments/dev|staging|prod/terraform.tfstate   one per environment
```

Locking is S3-native (`use_lockfile`, Terraform >= 1.10) rather than a
DynamoDB table - DynamoDB-based locking is deprecated.

## Not yet built

- Unit tests (`tests/` is empty; the PR gate runs container verification,
  not unit tests)
- Rollback on a post-deployment smoke-test failure
- Metrics and dashboards


Architecture diagrams live in the root `README.md`.
