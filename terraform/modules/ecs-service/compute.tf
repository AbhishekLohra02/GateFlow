# ===========================================================================
# THE EC2 CAPACITY THE CONTAINERS RUN ON.
#
# ECS does not provide servers on the EC2 launch type - it schedules onto
# servers you supply. This file supplies them.
# ===========================================================================

# The ECS-optimized AMI, read from an AWS-published SSM parameter rather than
# pinned to an ID.
#
# AMI IDs are region-specific AND change every time AWS rebuilds the image
# with security patches. A hardcoded ID is both region-locked and frozen at
# whatever CVEs existed the day it was copied. This always resolves to the
# current recommended build, which already has Docker and the ECS agent
# installed and enabled.
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

# ---------------------------------------------------------------------------
# Launch template: the blueprint the auto scaling group stamps out.
# ---------------------------------------------------------------------------
resource "aws_launch_template" "this" {
  name_prefix   = "${var.name_prefix}-lt-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  vpc_security_group_ids = [var.security_group_id]

  # How the instance learns which cluster to join.
  #
  # The ECS agent reads /etc/ecs/ecs.config at boot. Without this line the
  # agent starts, looks for a cluster literally named "default", fails to
  # find it, and the instance sits there healthy and useless while the
  # service reports "no container instances found".
  #
  # base64encode is required - EC2 expects user data base64-encoded.
  user_data = base64encode(<<-EOT
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.this.name}" >> /etc/ecs/ecs.config
  EOT
  )

  # IMDSv2 required, not optional.
  #
  # IMDSv1 answers any HTTP GET to 169.254.169.254 - including one made by a
  # server-side request forgery bug in your own app, which is how attackers
  # have stolen instance credentials repeatedly. IMDSv2 requires a PUT to
  # fetch a token first, which SSRF generally cannot do.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2 # 2, not 1: the hop from the container
  }

  # Recreate the template before destroying the old one. Without this, a
  # change that forces replacement destroys the template the ASG is still
  # referencing, and the apply fails midway.
  lifecycle {
    create_before_destroy = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name_prefix}-ecs-instance" }
  }
}

# ---------------------------------------------------------------------------
# Auto scaling group.
#
# Even at a fixed size of one, this is not pointless: if the instance dies or
# fails its health check, the ASG replaces it automatically. A bare
# aws_instance would just stay dead. Self-healing for free.
# ---------------------------------------------------------------------------
resource "aws_autoscaling_group" "this" {
  name                = "${var.name_prefix}-asg"
  vpc_zone_identifier = var.subnet_ids

  min_size         = var.instance_count
  max_size         = var.instance_count
  desired_capacity = var.instance_count

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  # ASG health checks look at EC2 status only. The ECS agent's health is not
  # checked here - the ECS service handles task-level health separately.
  health_check_type         = "EC2"
  health_check_grace_period = 120

  # ASG tags do NOT inherit the provider's default_tags, unlike every other
  # resource. This one has to be spelled out.
  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-ecs-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "GateFlow"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }
}
