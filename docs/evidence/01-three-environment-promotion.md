# Evidence 01 — One image, three environments

**Captured:** 2026-09-22
**Account:** 355421126727 · **Region:** us-east-1
**Commit / image tag:** `e93f339c93ef09a46daed8bd07fac3e38f79f791`

---

## What was run

From AWS CloudShell, each environment's running EC2 instance was looked up by
tag and called over the public internet:

```bash
for env in dev staging prod; do
  ip=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=gateflow-$env-ecs-instance" \
              'Name=instance-state-name,Values=running' \
    --query 'Reservations[].Instances[].PublicIpAddress' \
    --output text --region us-east-1 | tr '\t' '\n' | head -1)
  echo "$env ($ip) -> $(curl -sS --max-time 5 http://$ip:3000)"
done
```

## Result

```
dev     (44.202.121.247) -> {"message":"Hello from GateFlow","version":"dev"}
staging (18.212.5.161)   -> {"message":"Hello from GateFlow","version":"staging"}
prod    (52.202.40.51)   -> {"message":"Hello from GateFlow","version":"prod"}
```

---

## Why this is the central piece of evidence

Three independent environments, on three separate VPCs, each returning a
different `version` — **from a single container image digest.**

All three ECS task definitions reference the identical image:

```
355421126727.dkr.ecr.us-east-1.amazonaws.com/gateflow-app:e93f339c93ef09a46daed8bd07fac3e38f79f791
```

The image was built once, on one CI run, from one commit. It was never
rebuilt between environments — it was **promoted**.

That matters because it is the only thing that makes testing mean anything.
If each environment built its own image, the artifact tested in dev would not
be the artifact running in production, and everything proved in dev would
prove nothing about prod.

### The `version` field is the proof

`app/app.py` reads its version from the environment with a hardcoded fallback:

```python
os.environ.get("APP_VERSION", "v1")
```

None of the three responses say `v1`. So the value in each response cannot
have come from the image — it was injected at runtime by that environment's
ECS task definition. Same bytes, three configurations.

### Three separate networks

| Environment | VPC CIDR | Subnets | Instances |
|---|---|---|---|
| dev | 10.0.0.0/16 | 10.0.0.0/24, 10.0.1.0/24 | 1 |
| staging | 10.1.0.0/16 | 10.1.0.0/24, 10.1.1.0/24 | 1 |
| prod | 10.2.0.0/16 | 10.2.0.0/24, 10.2.1.0/24 | 2 |

Each spans two availability zones. Each has its own Terraform state file, so
a `terraform destroy` in one environment cannot see another's resources.

### How it got there

Merging to `main` ran, with no human command at any point:

```
build image → test in a container → scan → push to ECR
  → apply shared → deploy dev     → smoke test
                 → deploy staging → smoke test
                 → APPROVAL GATE  (required reviewer)
                 → deploy prod    → smoke test
```

Each stage runs only if the previous stage's smoke test passed. Production
was reached only after a human approved it.
