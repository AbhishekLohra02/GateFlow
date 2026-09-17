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

## Cost / timeline constraints
- AWS free-tier account expires ~10 days from 2026-09-17.
- EKS control plane is NOT free-tier covered (~$0.10/hr) - always flag
  before creating one, and tear down the same session once it's served its
  purpose. Don't leave paid AWS resources running unnecessarily.

## 10-day sequence (adjust dates as time passes)
1-2. Docker (images, Dockerfile, multi-stage builds, compose, push to ECR)
3-4. Kubernetes (concepts + local practice with kind, then real EKS)
5-6. Terraform (HCL fundamentals, then the actual infra: VPC/ECR/EKS)
7. CI/CD - GitHub Actions pipeline: PR checks -> dev -> staging -> prod
8. Testing pipeline depth + monitoring + the AI PR-summary step
9. Teardown AWS resources before free tier ends + polish repo/README/diagram
10. Interview prep - walk through the project, common interview questions

## Dev environment (decided 2026-09-17)
All hands-on work happens in a **GitHub Codespace**, not on the user's
laptop - they explicitly did not want Docker Desktop or anything else
installed locally. Machine is Windows 11 **Home** (no Hyper-V, so Docker
Desktop would have required a WSL2 install; rejected as too much local
footprint for a 10-day project).
- `.devcontainer/devcontainer.json` defines the environment: Python 3.12
  base (matches `app/Dockerfile`), `docker-in-docker` feature for a real
  Docker daemon, `aws-cli` feature for the Day 2 ECR push. kubectl and
  terraform features get added on their own days.
- User connects **VS Code Desktop -> remote Codespace**, so Claude runs
  inside the Codespace and can read/write files and run docker there.
- Codespaces free tier bills on wall-clock runtime: stop the Codespace
  when done. Same discipline as tearing down EKS.

## Status as of 2026-09-17
Day 1. Repo scaffolded, Flask app + Dockerfile written, `.devcontainer/`
added. Three local commits, **not yet pushed to GitHub** - user must
create an empty GitHub repo and push from their own terminal so their
auth stays local. That push is now a hard blocker: Codespaces requires
the remote repo to exist.
Nothing has been `docker build`-ed yet - the Dockerfile is written but
completely unverified. First task once the Codespace is up:
`docker build` / `docker run` / `curl`, plus `docker exec -it <id> whoami`
to prove the non-root `appuser` actually took effect.
