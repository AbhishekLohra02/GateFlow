# ===========================================================================
# TWO ROLES, AND THEY ARE NOT INTERCHANGEABLE.
#
# This is the single most confused part of ECS-on-EC2, so be clear on it:
#
#   instance role  -> assumed by the EC2 HOST. Lets the ECS agent register
#                     the machine into the cluster and report task status.
#   execution role -> assumed by the ECS SERVICE on your behalf, BEFORE the
#                     container starts. Lets it pull the image from ECR and
#                     create log streams.
#
# There is a third, the TASK role, which the running container itself uses to
# call AWS APIs. We have none - this app talks to nothing - so it is omitted.
# Giving an app a task role it does not need is how least privilege erodes.
# ===========================================================================

# ---------------------------------------------------------------------------
# Instance role: for the EC2 host running the ECS agent.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "instance_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      # ec2, not ecs-tasks: the EC2 service is what assumes this role when
      # it launches the instance. Getting this principal wrong produces an
      # instance that boots fine and never joins the cluster.
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name_prefix}-ecs-instance-role"
  assume_role_policy = data.aws_iam_policy_document.instance_assume.json
}

# AWS-managed policy with exactly the permissions the ECS agent needs:
# register the instance, poll for tasks, report state. Writing this by hand
# means re-deriving it every time AWS adds an agent API.
resource "aws_iam_role_policy_attachment" "instance_ecs" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# Session Manager. This is what replaces an SSH key and an open port 22:
# the SSM agent dials OUT to AWS, so you get a shell with no inbound rule,
# no key material, IAM-controlled access and CloudTrail logging.
resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# EC2 cannot be handed a role directly - it takes an INSTANCE PROFILE, which
# is a container for exactly one role. An IAM-only concept that exists purely
# because of how EC2 delivers credentials to the metadata service.
resource "aws_iam_instance_profile" "instance" {
  name = "${var.name_prefix}-ecs-instance-profile"
  role = aws_iam_role.instance.name
}

# ---------------------------------------------------------------------------
# Execution role: used by ECS itself to start the task.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "execution_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      # ecs-tasks, not ecs and not ec2. A mismatch here surfaces as
      # "unable to pull secrets or registry auth" with the task stuck in
      # PENDING - an error that names neither the role nor the principal.
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.execution_assume.json
}

# Grants ecr:GetAuthorizationToken, ecr:BatchGetImage and the CloudWatch Logs
# writes needed to create the task's log stream.
resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
