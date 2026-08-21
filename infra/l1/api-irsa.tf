# ---------------------------------------------------------------------------
# IRSA for the api.
#
# Fourth time: ALB controller, EBS CSI, ESO, and now YOUR code. Same three
# pieces every time - policy, role with a trust condition, annotated
# ServiceAccount.
#
# The difference: the first three were other people's controllers, shipped
# with a documented ServiceAccount name. This one is a name you choose, and
# getting it wrong produces AccessDenied with no hint about which condition
# failed.
# ---------------------------------------------------------------------------

locals {
  api_namespace       = "default"
  api_service_account = "api"
}

# Scoped to ONE bucket, and to the actions an upload endpoint actually needs.
#
# Note the two Resource entries. They are not the same ARN:
#   arn:aws:s3:::bucket        the bucket itself  -> ListBucket
#   arn:aws:s3:::bucket/*      objects inside it  -> Get/Put/DeleteObject
# Object actions on the bucket ARN, or ListBucket on the object ARN, are both
# silently denied. This single detail is the most common IRSA S3 mistake.
resource "aws_iam_policy" "api" {
  name        = "${local.cluster_name}-api"
  description = "Read and write documents in the securedocs bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [local.l0.documents_bucket_arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = ["${local.l0.documents_bucket_arn}/*"]
      },
    ]
  })

  tags = local.common_tags
}

# The role. "Trusted by" is the whole security story here.
#
# Principal Federated = the cluster's OIDC provider: only tokens signed by THIS
# cluster are considered at all.
#
# The two conditions narrow it from "any pod in the cluster" to one exact
# identity:
#   :sub  which ServiceAccount, as system:serviceaccount:<namespace>:<name>
#   :aud  who the token was minted for - blocks a token issued for something
#         else being replayed against STS
#
# Drop the :sub condition and every pod in the cluster can read the documents.
# That is the difference between IRSA and just using the node role.
resource "aws_iam_role" "api" {
  name = "${local.cluster_name}-api"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.this.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_host}:sub" = "system:serviceaccount:${local.api_namespace}:${local.api_service_account}"
          "${local.oidc_issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "api" {
  role       = aws_iam_role.api.name
  policy_arn = aws_iam_policy.api.arn
}

# The chart needs this ARN for the ServiceAccount annotation. Printed rather
# than wired automatically: ArgoCD deploys the chart from git, so the value has
# to be committed there. It is stable across rebuilds (the name is derived from
# the cluster name), so this is a one-time copy, not a per-rebuild chore.
output "api_role_arn" {
  description = "Put this in charts/securedocs/values-eks.yaml under api.serviceAccount.roleArn"
  value       = aws_iam_role.api.arn
}
