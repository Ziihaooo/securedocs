# ---------------------------------------------------------------------------
# GitHub Actions -> AWS, with no stored credentials.
#
# The obvious way to let CI push to ECR is an IAM user with an access key,
# pasted into GitHub secrets. That key is long-lived, invisible once stored,
# and leaks through logs, forks and screenshots. Rotating it means editing
# every repository that holds a copy.
#
# The same trick as IRSA instead: GitHub mints a short-lived signed token for
# each workflow run, AWS verifies the signature, and the run gets credentials
# valid for an hour. Nothing to store, nothing to rotate, nothing to leak.
#
#   IRSA            EKS signs a token   ->  a POD assumes a role
#   this            GitHub signs one    ->  a WORKFLOW RUN assumes a role
#
# L0 because it is permanent: CI must keep working while the cluster does not
# exist, which is most of the time.
# ---------------------------------------------------------------------------

# Teaches AWS to trust tokens signed by GitHub. One per account - if it already
# exists from other work, import it rather than creating a second.
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # Who the token is FOR. GitHub always mints tokens with this audience when a
  # workflow requests AWS credentials.
  client_id_list = ["sts.amazonaws.com"]

  # The CA thumbprint of GitHub's OIDC endpoint. AWS has verified this against
  # its own trust store since 2023 and ignores the value, but the field is
  # still required.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = local.common_tags
}

# The role CI wears. Everything about who may wear it is in the condition.
#
# The :sub claim GitHub puts in the token describes exactly where the workflow
# ran, and its shape is what you are pinning:
#
#   repo:OWNER/NAME:ref:refs/heads/main        a push to main
#   repo:OWNER/NAME:pull_request               a PR from ANY fork
#   repo:OWNER/NAME:environment:production     a run in a named environment
#
# Getting this wrong is the classic GitHub-OIDC breach. Leave the branch out:
#
#   "…:sub" = "repo:Ziihaooo/securedocs:*"
#
# and anyone who opens a pull request from a fork - which runs THEIR code -
# gets your ECR push credentials. Pin the full ref, always.
resource "aws_iam_role" "github_actions" {
  name = "securedocs-${local.environment}-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      # NOTE the shape of github_repo. This repository's OIDC tokens carry
      # numeric IDs in the subject:
      #
      #   repo:Ziihaooo@137987948/securedocs@1331597756:ref:refs/heads/argocd
      #           ^^^^^^^^^^                ^^^^^^^^^^^
      #
      # not the "repo:owner/name:..." every guide shows. A policy written from
      # the documented shape fails with a bare "Not authorized", and so does a
      # "repo:owner/name:*" wildcard - the mismatch occurs before the wildcard
      # begins. The only way to find it is to decode the token and read the
      # claim, which is what the diagnostic step in ci.yml does.
      #
      # The IDs are actually the better identifier: they survive a rename of
      # either the account or the repository, whereas names do not.
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/${var.github_branch}"
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

# What CI may do: push images, and nothing else.
#
# Note the two statements. ECR is unusual - the login step is an ACCOUNT-level
# call with no repository to scope it to, so GetAuthorizationToken must be
# Resource "*". Everything that touches actual image layers is scoped to the
# one repository.
#
# There is no ecr:DeleteImage and no ecr:BatchDeleteImage here. CI publishes;
# it never removes. A compromised workflow can add a bad image - which Kyverno
# will refuse to run in Week 3 - but it cannot erase the good ones.
resource "aws_iam_policy" "github_actions" {
  name        = "securedocs-${local.environment}-github-actions"
  description = "Push container images to the securedocs ECR repository"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", # is this layer already pushed?
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",                    # the manifest, once layers are up
          "ecr:BatchGetImage",               # read back, for cosign in Week 3
          "ecr:DescribeImages",
        ]
        Resource = [aws_ecr_repository.api.arn]
      },
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions.arn
}

# Goes into .github/workflows/ci.yml. Not a secret - it is only usable by a
# workflow running on the exact repo and branch named in the trust policy.
output "github_actions_role_arn" {
  description = "role-to-assume for the GitHub Actions workflow"
  value       = aws_iam_role.github_actions.arn
}
