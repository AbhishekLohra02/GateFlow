# GateFlow

A production-style, multi-environment CI/CD pipeline: every release moves
through automated gates (tests → dev → staging → manual approval → prod)
with nothing deployed by hand.

## Why this structure

This layout mirrors how a real platform/SRE team organizes a repo — the
guiding principle is **separation of concerns**: application code, the
infrastructure that runs it, the pipeline that ships it, and the
environment-specific config for each are all kept apart, so each can change
independently without the others needing to move. This is the industry
default (not a house style) because in a real team, different people usually
own each layer, and none of them should need to touch the others' territory
to do their job.

```
gateflow/
├── app/                 # the application itself - owned by app developers
├── k8s/                 # Kubernetes manifests - how the app runs
│   ├── base/             #   the shared, environment-agnostic definition
│   └── overlays/          #   per-environment differences (dev/staging/prod)
├── terraform/            # the cloud infrastructure the app runs ON
│   ├── modules/           #   reusable building blocks (a VPC, an EKS cluster...)
│   └── environments/      #   one folder per environment, each its own Terraform state
├── .github/workflows/    # the CI/CD pipeline itself
├── tests/                # unit + integration tests, run BY the pipeline
└── docs/                 # architecture notes, runbooks
```

## Why base/overlays for Kubernetes (not one YAML file per environment)

The naive approach is copy-pasting a full set of YAML manifests for dev,
staging, and prod. The problem: when you need to change something common to
all three (say, add a new environment variable every environment needs), you
now have to remember to edit it in three places, and drift between
environments creeps in silently. The standard fix is **Kustomize**
(built into `kubectl` since 1.14): `base/` holds the one true definition of
the app, and each `overlays/<env>/` holds only the *differences* for that
environment (replica count, resource limits, image tag). We'll build this
out on the Kubernetes days.

## Why one Terraform folder per environment (not one set of .tf files reused three times)

Terraform tracks real infrastructure in a **state file** — its record of
what it created and what it's responsible for. If dev, staging, and prod
shared one state file, a `terraform destroy` aimed at tearing down a test
resource in dev could touch prod. Giving each environment its own state
(via its own folder, or Terraform workspaces — we'll discuss the tradeoff
when we get there) is how real teams avoid that blast radius. We'll build
this out on the Terraform days.

## Status

- [x] Day 1 — `app/` and its Dockerfile
- [ ] Day 2 — multi-stage build refinement, docker-compose
- [ ] Day 3-4 — Kubernetes (`k8s/`)
- [ ] Day 5-6 — Terraform (`terraform/`)
- [ ] Day 7 — CI/CD pipeline (`.github/workflows/`)
- [ ] Day 8 — testing depth (`tests/`) + monitoring + AI PR-summary step
- [ ] Day 9 — teardown + polish
- [ ] Day 10 — interview prep
