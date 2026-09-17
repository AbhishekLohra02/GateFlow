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

# TEMPORARY, AND DELIBERATE.
#
# Scoping IAM before you know which API calls Terraform actually makes means
# guessing, then losing hours to AccessDenied errors that name an action but
# never the resource. The professional move is to start broad, capture the
# real calls from CloudTrail once the infrastructure exists, and narrow to
# that - which is a day 8 task tracked in CLAUDE.md.
#
# Saying this out loud in a review is the difference between "I started
# broad and tightened from observed usage" and "I left it as admin".
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
