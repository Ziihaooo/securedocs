# ---------------------------------------------------------------------------
# External Secrets Operator.
#
# Solves the last manual step: a rebuilt cluster has no postgres-credentials
# Secret, so postgres never starts.
#
#   AWS Secrets Manager   holds the real password (set out-of-band)
#          ↑ reads via IRSA
#   ESO                   creates a normal Kubernetes Secret from it
#          ↑ references by NAME only
#   git                   holds a reference, never a value
#
# Third IRSA example. Same three pieces as the ALB controller and EBS CSI.
# ---------------------------------------------------------------------------

locals {
  eso_namespace       = "external-secrets"
  eso_service_account = "external-secrets"
}

# Read-only, and scoped to ONE secret ARN rather than "*". If this role is ever
# abused it can read the postgres password and nothing else.
resource "aws_iam_policy" "external_secrets" {
  name        = "${local.cluster_name}-external-secrets"
  description = "Read the postgres credentials from Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = [local.l0.postgres_secret_arn]
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role" "external_secrets" {
  name = "${local.cluster_name}-external-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.this.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_host}:sub" = "system:serviceaccount:${local.eso_namespace}:${local.eso_service_account}"
          "${local.oidc_issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.external_secrets.arn
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = local.eso_namespace
  create_namespace = true
  version          = "0.10.5"

  # ESO ships CRDs (SecretStore, ExternalSecret). Installing them with the
  # chart keeps their lifecycle tied to it.
  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = local.eso_service_account
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.external_secrets.arn
  }

  timeout = 600

  depends_on = [
    aws_eks_node_group.default,
    aws_iam_role_policy_attachment.external_secrets,
    aws_route.private_nat,
  ]
}
