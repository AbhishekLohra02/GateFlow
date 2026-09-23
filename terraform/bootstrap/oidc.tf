# Tells AWS to trust GitHub as an identity provider.
#
# This is what makes keyless CI possible. GitHub signs a short-lived token
# describing WHICH repo, branch and workflow is running; AWS verifies that
# signature and exchanges it for temporary STS credentials.
#
# The alternative - an IAM user with an access key pasted into GitHub
# secrets - means a credential that never expires, in a public repo's CI,
# recoverable from any leaked log or compromised third-party action. It is
# the most common root cause of cloud account compromise via CI.
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # The audience. GitHub sets `aud` to this when configure-aws-credentials
  # requests the token; AWS refuses the exchange if it does not match.
  client_id_list = ["sts.amazonaws.com"]

  # Since 2023 AWS validates GitHub's certificate against its own trusted
  # root CAs and effectively ignores these, but the argument is still
  # required by the API. Historically this had to be rotated by hand
  # whenever GitHub's CA changed - a fun way to break every pipeline at once.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

# The trust policy - WHO may assume the role. This is the security boundary
# of the entire pipeline, so it is built as a data source where every
# condition is explicit and reviewable in the diff.
locals {
  # GitHub's IMMUTABLE subject format:
  #   repo:<owner>@<owner_id>/<repo>@<repo_id>:<context>
  # e.g. repo:AbhishekLohra02@217813897/GateFlow@1374185994:pull_request
  #
  # Built from the same variables as the ID conditions below so the two can
  # never drift apart.
  github_owner = split("/", var.github_repository)[0]
  github_repo  = split("/", var.github_repository)[1]

  oidc_sub_prefix = "repo:${local.github_owner}@${var.github_repository_owner_id}/${local.github_repo}@${var.github_repository_id}"
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # Must be the audience we registered above.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # THE conditions that matter - the security boundary of the pipeline.
    #
    # These pin the role to THIS repository, and nothing else on GitHub.
    #
    # We do it on the numeric IDs rather than on `sub` string-matching,
    # because GitHub now issues IMMUTABLE subject claims. The sub for this
    # repo reads:
    #
    #   repo:AbhishekLohra02@217813897/GateFlow@1374185994:pull_request
    #
    # not the `repo:owner/name:ref` form every tutorial shows. A trust
    # policy written the old way silently never matches, and AWS returns a
    # bare "Not authorized to perform sts:AssumeRoleWithWebIdentity" that
    # names neither the claim nor the condition that failed.
    #
    # Matching IDs is also strictly safer than matching names. Rename this
    # repo or the account and someone else can register the old name - their
    # tokens would then satisfy a name-based policy. Numeric IDs cannot be
    # re-registered, so this survives a rename in both directions.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository_owner_id"
      values   = [var.github_repository_owner_id]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository_id"
      values   = [var.github_repository_id]
    }

    # AWS REQUIRES this one. A trust policy for a GitHub OIDC provider is
    # rejected outright unless it constrains `sub` or `job_workflow_ref` to
    # something narrower than "*":
    #
    #   MalformedPolicyDocument: Trust policy ... must evaluate ...
    #   token.actions.githubusercontent.com:sub or ...:job_workflow_ref
    #   which is not scoped to all
    #
    # That is AWS refusing to let you create the over-broad policy that the
    # ID conditions above were meant to avoid. The ID conditions are still
    # worth keeping: they are immutable, so they hold even if this repo or
    # the account is renamed and the names in `sub` change underneath us.
    #
    # The trailing :* covers every workflow context - pull_request,
    # ref:refs/heads/main, environment:prod - which is what we need while a
    # single role serves both the PR gate and deploys.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.oidc_sub_prefix}:*"]
    }

    # NOTE: any workflow in this repo can assume the role, on any branch or
    # PR. That is intentional for now - `terraform plan` must run on pull
    # requests, so pinning to refs/heads/main would break the PR gate.
    #
    # Day 7 tightens this: the prod deploy gets its OWN role, conditioned on
    # the `environment` claim, so a PR can plan but only an approved
    # deployment can touch production.
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "gateflow-github-actions"
  description        = "Assumed by GitHub Actions via OIDC to run Terraform and push images."
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json

  # Caps how long the credentials live regardless of what the workflow asks
  # for. A long-running job is not a reason to hold admin credentials for
  # 12 hours.
  max_session_duration = 3600
}

# ===========================================================================
# THE CI ROLE'S PERMISSIONS.
#
# This started as AdministratorAccess, deliberately: scoping IAM before you
# know which API calls Terraform actually makes means guessing, then losing
# hours to AccessDenied errors that name an action but never the resource.
# Start broad, observe what is actually used, then narrow to that.
#
# This is the narrowed version. Two things make it meaningful rather than
# cosmetic:
#
#   1. IAM access is restricted to roles and instance profiles named
#      gateflow-* . The pipeline can create the roles its own workloads
#      need and nothing else.
#   2. An explicit DENY protects the bootstrap resources from the pipeline
#      - its own role, the identity provider that lets it authenticate, and
#      the bucket holding everyone's state.
#
# Point 2 is the one that matters. Without it, "IAM access limited to
# gateflow-*" would include `gateflow-github-actions` - the role the
# pipeline itself assumes - so anyone able to merge could grant that role
# more permissions and walk straight back up to admin. An explicit Deny
# always beats an Allow in IAM, whatever else is attached, which is what
# makes this a real boundary rather than a naming convention.
# ===========================================================================

data "aws_iam_policy_document" "github_actions" {
  # -------------------------------------------------------------------
  # Networking and compute. Left wide WITHIN these services on purpose:
  # EC2 resource-level permissions are notoriously incomplete (many
  # actions simply do not support resource ARNs), so a resource-scoped
  # policy here would be a false sense of security that breaks
  # unpredictably. The real boundary for these is the account itself.
  # -------------------------------------------------------------------
  statement {
    sid    = "NetworkingAndCompute"
    effect = "Allow"
    actions = [
      "ec2:*",
      "autoscaling:*",
      "elasticloadbalancing:Describe*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ContainerOrchestration"
    effect = "Allow"
    actions = [
      "ecs:*",
      "ecr:*",
      "logs:*",
      "application-autoscaling:*",
    ]
    resources = ["*"]
  }

  # Read-only. Needed for the ECS-optimized AMI lookup, which reads an
  # AWS-published SSM parameter. No write access - the pipeline has no
  # business creating parameters.
  statement {
    sid       = "ReadPublicSsmParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["*"]
  }

  # -------------------------------------------------------------------
  # IAM, scoped by NAME.
  #
  # Terraform must create the ECS instance and execution roles, so this
  # cannot be removed - but it can be bounded. Every role this project
  # creates is prefixed gateflow-, so the policy allows exactly that
  # namespace and nothing else.
  # -------------------------------------------------------------------
  statement {
    sid    = "ManageProjectRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:CreateServiceLinkedRole",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/gateflow-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/gateflow-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/*",
    ]
  }

  # PassRole is the quiet one. Handing a role to a service is how
  # privilege escalation usually happens: if the pipeline could pass ANY
  # role to ECS, it could start a task running as an administrator role
  # and read whatever that role can read. Restricted to this project's
  # roles, and to the two services that legitimately need them.
  statement {
    sid       = "PassProjectRolesToEcsAndEc2"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/gateflow-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com", "ec2.amazonaws.com"]
    }
  }

  # Terraform state. The bucket itself, and objects within it.
  statement {
    sid    = "TerraformState"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketVersioning",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
  }

  statement {
    sid       = "ReadOwnIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity", "iam:ListRoles", "iam:GetPolicy"]
    resources = ["*"]
  }

  # -------------------------------------------------------------------
  # THE BOUNDARY. An explicit Deny cannot be overridden by any Allow.
  #
  # Without this, "roles named gateflow-*" would include the pipeline's
  # OWN role - so a merged pull request could attach AdministratorAccess
  # to it and escalate straight back to where we started.
  # -------------------------------------------------------------------
  statement {
    sid    = "DenyTouchingOwnIdentity"
    effect = "Deny"
    actions = [
      "iam:*Role*",
      "iam:*Policy*",
      "iam:*OpenIDConnect*",
    ]
    resources = [
      aws_iam_role.github_actions.arn,
      aws_iam_openid_connect_provider.github.arn,
    ]
  }

  # The state bucket is created and protected by the bootstrap stack. The
  # pipeline reads and writes state inside it; it must never be able to
  # delete the bucket, disable versioning, or open it to the public.
  statement {
    sid    = "DenyDestroyingStateBucket"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:PutBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutBucketPublicAccessBlock",
      "s3:DeleteBucketPolicy",
    ]
    resources = [aws_s3_bucket.state.arn]
  }
}

resource "aws_iam_policy" "github_actions" {
  name        = "gateflow-github-actions-policy"
  description = "Scoped permissions for the GateFlow CI pipeline."
  policy      = data.aws_iam_policy_document.github_actions.json
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions.arn
}
