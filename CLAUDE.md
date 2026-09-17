# GateFlow — context for Claude

Read this fully before helping with anything in this repo. It captures the
project goal, decisions already made, and how the user wants to be taught.

## What this is
A production-style, multi-environment CI/CD pipeline, built as a learning
project to prepare for DevOps job interviews in ~10 days (AWS free-tier
account expires soon, so AWS-touching work is front-loaded). The pipeline
itself is the point of the project — the deployed app is deliberately kept
small so it never distracts from that.

**The pipeline, end to end:**
- On every PR: lint, unit tests, Docker build, Trivy vulnerability scan,
  results posted back on the PR. Nothing merges if it fails.
- On merge to main: build+tag image, push to ECR, auto-deploy to **Dev**,
  run integration/smoke tests against the live Dev deployment.
- Dev passes -> auto-promote to **Staging**, tests again, then a **manual
  approval gate**.
- On approval -> roll out to **Prod** (rolling/blue-green), final smoke
  test, automatic rollback on failure.
- Small AI touch: the pipeline uses an LLM to auto-generate a plain-English
  PR summary/release notes from the diff, posted as a PR/release comment.

## The app (`app/`)
Python + Flask, served by gunicorn (not Flask's dev server - not
production-safe). Currently a minimal `/` and `/health` endpoint. Planned
next addition: a small `/generate` endpoint that sends a prompt to an LLM
API and returns generated code as text (scoped deliberately small - NOT a
full "AI writes and executes arbitrary apps" platform; that was explicitly
considered and rejected as too large a scope for the timeline and as a
security/sandboxing problem of its own). RAG-based ideas were also
explicitly rejected earlier (user's request, wanted something less overdone).

## Tech / language choices (deliberate, don't second-guess these)
- App: Python/Flask + gunicorn.
- Dockerfile: `python:3.12-slim` base (NOT alpine - musl/glibc breaks C
  extensions for many Python packages, a real common gotcha). Multi-stage
  build (deps stage installs with `pip install --user`, runtime stage
  copies only the installed packages - keeps final image lean). Runs as a
  non-root user (`useradd --create-home appuser`) - slim Python image
  doesn't ship a non-root user by default the way node:alpine does.
- Kubernetes manifests (`k8s/`): YAML - Kubernetes' declared-state format.
  Structured as `base/` (shared definition) + `overlays/dev|staging|prod`
  (per-environment differences) - Kustomize pattern, not copy-pasted YAML
  per environment.
- GitHub Actions (`.github/workflows/`): YAML.
- Terraform (`terraform/`): **HCL, not YAML** - this was explicitly
  corrected with the user, who initially assumed Terraform used YAML.
  Structured as `modules/` (reusable building blocks) + one folder per
  `environments/dev|staging|prod`, each with its OWN Terraform state, so a
  destroy in one environment can never touch another.
- Any custom pipeline scripts (smoke tests, the AI PR-summary step): Python.

## How the user wants to be taught (important - follow this)
- The user is NOT comfortable writing code and does not want to write app
  logic themselves. Claude should write the actual files.
- BUT the user explicitly wants deep conceptual understanding, not just
  working code - they've built a similar pipeline before with AI doing all
  the work, and this time want to actually understand it so they can
  defend every design choice in a job interview walkthrough.
- For every file/config created, explain: what it does, WHY it's written
  that way (industry-standard reasoning), what the common mistake/deviation
  is, and what breaks/goes wrong if you don't do it that way. This "why +
  consequence" framing is what the user explicitly asked for - don't just
  hand over working config without it.
- The user DOES run operational commands themselves (docker build/run,
  curl, git, and later kubectl/terraform) - that's their hands-on part.
  They use Git Bash in VS Code's integrated terminal (not PowerShell).
- Don't scaffold/build large chunks unasked - earlier in the project the
  user pushed back hard on Claude generating a full project before they'd
  agreed to the plan ("why are you creating everything on your own, wait
  first"). Confirm significant direction changes before building.
- User is a complete beginner at Docker/Kubernetes but already knows core
  AWS (EC2, S3, IAM, VPC) - no need to re-explain AWS basics.

## Repo structure and why
```
gateflow/
├── app/                  the application (Python/Flask + Dockerfile)
├── k8s/base + overlays/  Kubernetes manifests (Kustomize pattern)
├── terraform/modules + environments/   infra-as-code, one state per env
├── .github/workflows/    the CI/CD pipeline itself
├── tests/                unit + integration tests the pipeline runs
├── docs/architecture.md  living architecture doc, fill in as we build
└── README.md             full explanation of the structure/why
```
See root `README.md` for the fuller reasoning on base/overlays and
per-environment Terraform state.

## Two-phase plan (decided 2026-09-17, user's own idea - agreed)
User requires the project to stay in free tier. EKS is the ONLY component
with no free tier at all, so the project splits:
- **Phase 1** - Terraform + ECS on EC2, NO Kubernetes. Genuinely $0.
- **Phase 2** - migrate the same app/pipeline to Kubernetes on `kind`
  (free). Optional short EKS proving run later.
Bonus: this yields a *migration* story ("built on ECS, migrated to k8s"),
which interviews better than a greenfield k8s deploy.
See `docs/architecture.md` for the full Phase 1 design and reasoning.

## Cost model (must stay ~$0)
Free and confirmed via AWS pricing pages (researched 2026-09-17):
- VPC/subnets/IGW/route tables/security groups/IAM: always free.
- **ECS orchestration: no charge on EC2 launch type** - you pay only for
  EC2/EBS/public IPv4 underneath.
- EC2 t3.micro 750 hrs/mo; ECR 500MB; CloudWatch Logs 5GB.
- S3 + DynamoDB for Terraform remote state + locking: free tier.
- Codespaces (spending limit $0 by default - cannot overbill), GitHub
  Actions (unlimited on public repos), ghcr.io, GitHub Models.

NEVER create these - each is the difference between $0 and ~$50/mo:
- **NAT Gateway** (~$33/mo). Most community VPC modules add one BY
  DEFAULT. Use public subnets instead. #1 surprise-bill cause.
- **ALB/Ingress** (~$16/mo). Note a k8s `Service: LoadBalancer` creates
  one implicitly - Terraform won't show it but AWS bills it.
- **EKS** ($0.10/hr, no free tier). Deferred to Phase 2, optional.
- **Fargate** (no free tier at all).
Also: since Feb 2024 every public IPv4 costs $0.005/hr (~$3.60/mo) once
free tier lapses.

**RESOLVED 2026-09-17:** user created the AWS account a few months ago,
so it is on the **new Free Plan** (post 2025-07-15), NOT the legacy
12-month tier. Confirmed from AWS docs:
- $100 credits on signup, up to $100 more from onboarding activities.
- Plan ends after **6 months OR when credits run out**, whichever first.
- **"You will not incur any charges during this period until you upgrade
  to a paid account plan."** So on the Free Plan the user CANNOT be
  billed money. The real constraint is credit burn + account lifetime.
- At expiry AWS **closes the account**; 90 days to upgrade and recover
  data before permanent deletion.
- Everything this project needs IS available on the Free Plan, including
  EC2, ECS, **EKS**, ECR, S3, DynamoDB, VPC, IAM, CloudWatch, ELB,
  CodeDeploy, CodeBuild, Systems Manager, STS, Budgets.
- Restricted: Marketplace (Bedrock/Free only), Reserved Instances,
  Savings Plans, hardware. None of which we need.

**Consequence - the constraint is TIME, not money.** Credits expire
worthless when the account closes, so hoarding them is pointless. Do the
AWS-dependent work early and capture evidence into the repo, because the
account (and everything in it) disappears at expiry. The REPO is the
portfolio, not the AWS account.

**Still to check:** exact credit balance and plan end date - Billing and
Cost Management -> Free tier. That date is the real project deadline.

## Phase 1 day sequence
1. Verify the container (build/run/curl/whoami) + unit tests. <- HERE
2. Terraform fundamentals; remote state backend (S3+DynamoDB) + ECR repo.
3. Network module: VPC, public subnet, IGW, security group.
4. ECS module: cluster, EC2 capacity, task definition, service. Dev up.
5. Replicate to staging/prod as separate stacks with separate state.
6. GitHub Actions: OIDC to AWS, PR checks workflow.
7. Deploy pipeline: dev -> staging -> manual approval -> prod.
8. Smoke tests, auto-rollback, AI PR-summary step (GitHub Models).
9. Teardown, README, diagram.
10. Interview prep.

## Dev environment (decided 2026-09-17)
All hands-on work happens in a **GitHub Codespace**, not the user's laptop
- they explicitly did not want Docker Desktop or anything installed
locally. Windows 11 **Home** (no Hyper-V; Docker Desktop would have needed
a WSL2 install - rejected).
- `.devcontainer/devcontainer.json`: Python 3.12 base (matches
  `app/Dockerfile`), `docker-in-docker`, `aws-cli`. Terraform feature gets
  added on day 2.
- User connects **VS Code Desktop -> remote Codespace**.
- Stop the Codespace when done; core-hours burn on wall-clock runtime.

## Status as of 2026-09-17
Day 1. Repo scaffolded, Flask app + Dockerfile + `.devcontainer/` +
`docs/architecture.md` + `.github/workflows/ci.yml` written and pushed to
https://github.com/AbhishekLohra02/GateFlow - repo is now **public**.

**User declined to create a Codespace** and will not install Docker. So:
- Claude writes every file locally; the user commits and pushes.
- **GitHub Actions is the execution environment.** CI builds the image,
  runs the container, curls both endpoints, asserts `whoami` == appuser,
  and runs Trivy. Later it will run terraform plan/apply too.
- No interactive debugging is possible. Feedback loop is a git push.
- AWS work is done in the browser console.
- This pulled the CI pipeline forward from day 7 to day 1.

Outstanding:
- `ci.yml` not yet pushed/verified - the Dockerfile is STILL unbuilt and
  unverified. This is the immediate next milestone.
- AWS Budget alert not yet created.
- Credit balance / plan end date not yet checked.
