# ---------------------------------------------------------------------------
# The cluster: a logical grouping of capacity and services. Free - it is just
# a namespace in the ECS control plane, you pay only for the EC2 underneath.
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"

  setting {
    # Per-service CPU/memory metrics in CloudWatch. Free at this volume, and
    # without it you are debugging a restarting container with no numbers.
    name  = "containerInsights"
    value = "enabled"
  }
}

# ---------------------------------------------------------------------------
# Log destination.
#
# Created explicitly rather than letting ECS auto-create it, for one reason:
# an auto-created log group retains logs FOREVER. That is a slow leak past
# the 5GB free tier, and it is invisible until it bills.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# Task definition: the blueprint for a running container. The ECS equivalent
# of a Kubernetes pod spec, and it maps across almost one-to-one.
#
# Task definitions are IMMUTABLE and VERSIONED. Terraform does not edit this
# in place - every change registers a new revision (:1, :2, :3). That is what
# makes rollback possible: the previous revision still exists.
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "app" {
  family = var.name_prefix

  # bridge, not awsvpc.
  #
  # awsvpc gives each task its own ENI and private IP - cleaner, and required
  # on Fargate. But ENIs per instance are capped by instance type, and on a
  # t3.micro that cap is brutally low. bridge maps a container port to a host
  # port on the shared instance ENI, which is what lets us reach the app on
  # the instance's public IP with no load balancer.
  network_mode = "bridge"

  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.execution.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = var.image
      essential = true

      # cpu is a SOFT limit - 1024 units = 1 vCPU, and a container can burst
      # above its share when the host is idle. memory is a HARD limit: exceed
      # it and the kernel OOM-kills the container. Set it too low and you get
      # mysterious restarts with exit code 137.
      cpu    = var.task_cpu
      memory = var.task_memory

      portMappings = [
        {
          containerPort = var.app_port
          hostPort      = var.app_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "APP_VERSION", value = var.environment },
        { name = "PORT", value = tostring(var.app_port) }
      ]

      # Container-level health check, run by the ECS agent INSIDE the
      # container. Distinct from the ASG's EC2 check: this one knows whether
      # the app is serving, not merely whether the machine is powered on.
      #
      # Uses python, NOT curl - the python:3.12-slim base image does not ship
      # curl, so a curl-based check fails instantly with "command not found"
      # and the task is killed as unhealthy forever. A genuinely common trap.
      healthCheck = {
        command = [
          "CMD-SHELL",
          "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:${var.app_port}/health').status==200 else 1)\""
        ]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30 # grace window before failures count, for slow starts
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# The service: keeps desired_count copies of the task running, replaces them
# when they die, and performs rolling deployments on change.
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "app" {
  name            = "${var.name_prefix}-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "EC2"

  # DEPLOYMENT MATH, and it is forced on us by this architecture.
  #
  # The task binds host port 3000. Only one container can hold a given host
  # port on a given instance - so with one instance, the OLD task must stop
  # before the NEW one can start. That makes a brief outage unavoidable.
  #
  # minimum_healthy_percent = 0 permits it. The honest alternative is a load
  # balancer with dynamic host ports, which buys zero-downtime deploys for
  # about $16/month. That trade is deliberate and documented in
  # docs/architecture.md.
  deployment_minimum_healthy_percent = var.deployment_min_healthy_percent
  deployment_maximum_percent         = var.deployment_max_percent

  # Roll back automatically if the new deployment never reaches a steady
  # state. Without it a bad image leaves the service stuck retrying forever
  # while the previous, working version is already gone.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # The ASG must exist and be registering instances before the service tries
  # to place a task. Terraform cannot infer this: there is no direct
  # reference between them, only an indirect one through the cluster.
  depends_on = [aws_autoscaling_group.this]
}
