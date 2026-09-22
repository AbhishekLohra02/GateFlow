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

**RESOLVED 2026-09-17 - THE DEADLINE IS 2026-09-27.** Checked in Billing
and Cost Management -> Free tier:
- **Free access ends Sep 27, 2026** (11 days remaining as of 2026-09-17).
- **Credits remaining: $119.72** - essentially untouched.

Consequence, and it changes the cost calculus: the Phase 1 design burns
~$0/day because every component is free-tier covered, so that $119.72
will expire **unspent and worthless** when the account closes. Credits are
NOT a constraint. The only real constraints are (a) the Sep 27 wall and
(b) not upgrading to a paid plan.

The "NEVER create these" list above still governs the MAIN build - not
because the money matters now, but because a lean VPC is the better
engineering story and adding infra under a hard deadline is risk. But the
expiring credits make a deliberate, TIME-BOXED spend rational at the end
if days 2-8 land on schedule (rough daily burn: EKS $2.40, NAT $1.08,
ALB ~$0.60 - all three for 10 days is ~$42 of a $119.72 balance):
- the optional EKS proving run, and/or
- one ALB run to capture what the no-ALB design trades away.
Neither is committed. Both need explicit user sign-off first.

**User's plan (stated 2026-09-17): compress day-sequence steps 2-8 into
~3 days**, at 5+ hrs/day. Do not re-raise schedule concerns. If that
lands, the AWS account still has ~7 days of life and ~$119 of expiring
credits left over - which reopens **EKS as a real option inside the
account's lifetime**, not just the optional post-hoc proving run. Raise
that decision once steps 2-8 are done, not before.

**Evidence capture is now urgent.** The account and everything in it is
deleted after Sep 27. Every terraform plan/apply output, CI run, ECS
console view and smoke-test result must land in the REPO (docs/evidence/
+ architecture.md) as it happens, not "later".

## Terraform stack layout (decided 2026-09-17, user's call)

Bootstrap is kept SEPARATE from anything CI runs. Not tidiness - a security
boundary:
- `terraform/bootstrap/` - **human-run from CloudShell, once.** Owns the S3
  state bucket, the GitHub OIDC provider, and the `gateflow-github-actions`
  IAM role. CI must never manage these: if the pipeline's Terraform owned
  the role the pipeline assumes, anyone able to merge a PR could grant that
  role more permissions (privilege escalation). Likewise a stack that can
  delete the bucket holding its own state is one bad plan from
  unrecoverable. Resolves its own chicken-and-egg by applying with local
  state, then `terraform init -migrate-state` into the bucket it created.
  Bucket carries `prevent_destroy = true`.
- `terraform/shared/` - **CI-run.** Resources shared by all environments
  (ECR). One repo, not one per env, so the exact image tested in dev is the
  one promoted to prod.
- `terraform/environments/{dev,staging,prod}/` - **CI-run**, one state key
  each.

**State locking uses S3 `use_lockfile = true` (Terraform >= 1.10), NOT
DynamoDB.** This supersedes the DynamoDB references elsewhere in this file
and in docs/architecture.md. DynamoDB-based locking is deprecated; S3 does
it natively via conditional writes. No lock table is created.

**Day 2 COMPLETE (2026-09-17).** Bootstrap applied from CloudShell:
S3 state bucket `gateflow-tfstate-355421126727` (versioned, encrypted,
public access blocked, `prevent_destroy`), GitHub OIDC provider, and the
`gateflow-github-actions` role. Bootstrap state migrated into that bucket.
CI authenticates to AWS keylessly; `terraform-apply` (main only, gated on
both PR jobs) created ECR
`355421126727.dkr.ecr.us-east-1.amazonaws.com/gateflow-app`. A PR plans, a
merge applies - that asymmetry is the gate.

Open: `.terraform.lock.hcl` is still not committed (CI regenerates it each
run); CI role still has AdministratorAccess, narrows on Day 8.
Account ID `355421126727`.

**Two OIDC gotchas that cost real time - do not re-learn these:**
1. GitHub issues **immutable subject claims**:
   `repo:AbhishekLohra02@217813897/GateFlow@1374185994:pull_request`, NOT
   the `repo:owner/name:ref` form every tutorial shows. A name-based `sub`
   pattern silently never matches, and AWS returns only "Not authorized to
   perform sts:AssumeRoleWithWebIdentity" - naming neither the claim nor
   the condition that failed.
2. AWS **rejects** a GitHub OIDC trust policy that does not constrain `sub`
   or `job_workflow_ref` (`MalformedPolicyDocument ... not scoped to all`).
   Conditioning only on `repository_id`/`repository_owner_id` is not
   allowed - though those are worth keeping alongside it, since they
   survive a repo or account rename.

Useful IDs: owner_id `217813897`, repo_id `1374185994`.

**CloudShell notes:** `$HOME` is **per-region** - open it anywhere but
us-east-1 and the repo and terraform binary appear to have vanished. Its
1GB quota is too small for the AWS provider (~700MB), hence
`TF_DATA_DIR=/tmp/tfdata`, which means re-running `terraform init` each
session since /tmp is wiped.

## Phase 1 day sequence
1. Verify the container (build/run/curl/whoami) + unit tests. DONE
2. Terraform fundamentals; remote state backend (S3) + ECR repo. DONE
3. Network module: VPC, public subnet, IGW, security group. DONE
4. ECS module: cluster, EC2 capacity, task definition, service. DONE
5. Replicate to staging/prod as separate stacks with separate state. <- HERE
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

## Status as of 2026-09-19

**Days 3-4 COMPLETE. The app is DEPLOYED AND SERVING on AWS.**

Live in us-east-1: VPC `gateflow-dev-vpc`, two public subnets, IGW, SG,
ASG `gateflow-dev-asg` running one t3.micro, ECS cluster
`gateflow-dev-cluster`, service `gateflow-dev-svc`, log group
`/ecs/gateflow-dev`. Verified over the public internet: HTTP 200,
`Server: gunicorn`, body `{"message":"Hello from GateFlow","version":"dev"}`.
The `dev` label proves APP_VERSION reached the container from the task
definition (the app's own fallback is `v1`).

Pipeline is now four jobs and fully green on main (run #16, 3m52s):
build-and-verify -> terraform matrix (shared + dev) -> terraform-apply
(shared) -> deploy-dev. deploy-dev applies, waits for ECS steady state,
then SMOKE TESTS the deployment: looks up the instance IP, prints it to
the job log, curls /health with retries, curls /, and asserts
`"version":"dev"` in the response. Red if the app does not answer.

`docs/knowledge-transfer.md` (586 lines, no code) is the plain-language
build narrative + interview prep. **Keep it updated each session** - the
user asked for this explicitly; update it on the feature branch so doc and
code land on main together.

Notes / gotchas learned:
- The user's local network blocks outbound port 3000, so the deployed app
  is unreachable from their laptop but fine from CloudShell and from GitHub
  runners. NOT an AWS problem. Diagnostic: a cloud SG block drops packets
  and curl hangs ~30s; a local block fails instantly ("Host unreachable"
  in ~1ms). User said to ignore it; do NOT re-raise moving to port 80.
- Task definitions are immutable, so any image tag change shows as
  "must be replaced" (1 destroy) in the plan. That is NORMAL. When reading
  plans, look at WHAT is destroyed, not the count.
- User deletes local branches with `git branch -d` before the PR is merged;
  `-d` only checks the commit exists on the remote, not that it reached
  main. Warn before suggesting branch cleanup.

Outstanding:
- `.gitattributes` still not added (LF/CRLF). Becomes a real problem when
  step 8 adds shell scripts: CRLF in a script run inside Linux fails with
  `bash: No such file or directory`. Offered twice, not yet accepted.
- CI role still has AdministratorAccess; narrows on day 8.
- `.terraform.lock.hcl` still not committed.
- Evidence capture into `docs/evidence/` still not done - the CloudShell
  `curl -v` output, pipeline screenshots and EC2/ECS console views. Account
  is DELETED 2026-09-27. This is urgent and keeps slipping.
- Unit tests (`tests/`) still empty.
