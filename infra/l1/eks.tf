# ---------------------------------------------------------------------------
# IAM role for the CONTROL PLANE.
#
# Not the same as the node role. This one lets the EKS service itself manage
# ENIs, load balancers and security groups on your behalf.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${local.cluster_name}-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------------------------
# The cluster. ~10 minutes to create, ~10 to destroy.
# Billed at $0.10/hour from the moment it exists, with or without nodes.
# ---------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    # Control-plane ENIs land in these subnets. Private, because nothing about
    # the control plane needs a public address — the public API ENDPOINT is a
    # separate, AWS-managed thing.
    subnet_ids = local.l0.private_subnet_ids

    # Public: kubectl from your laptop.
    # Private: nodes reach the API without leaving the VPC.
    endpoint_public_access  = true
    endpoint_private_access = true

    # Anyone on the internet may REACH the endpoint — they still need valid
    # credentials to do anything. Production restricts this to office/VPN CIDRs.
    # A home IP changes, so locking it down here would lock you out.
    public_access_cidrs = var.api_public_access_cidrs
  }

  access_config {
    # "API" = EKS Access Entries, the current mechanism.
    # The old way was the aws-auth ConfigMap: edit YAML inside the cluster to
    # grant access, unmanaged by Terraform, and easy to lock yourself out of.
    authentication_mode = "API"

    # Grants cluster-admin to whoever runs this apply — you.
    # Without it you create a cluster nobody can kubectl into, including
    # yourself, and the only fix is to recreate it. AWS account admin gives
    # you ZERO Kubernetes permissions; the two systems are separate.
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Control-plane logs to CloudWatch. Off by default and genuinely useful:
  # "audit" is the only record of who did what in the cluster.
  # Costs CloudWatch ingestion — enabled_cluster_log_types = [] to disable.
  enabled_cluster_log_types = var.cluster_log_types

  tags = local.common_tags

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# ---------------------------------------------------------------------------
# OIDC provider — what makes IRSA possible.
#
# Registers the cluster's own identity provider with IAM, so a Kubernetes
# ServiceAccount token can be exchanged for AWS credentials. Same trust model as
# the Bitbucket -> AWS OIDC federation in AceArena, pointed at the cluster
# instead of a CI system.
#
# Without this, pods can only use the NODE's IAM role — meaning every pod on a
# node shares one set of permissions.
# ---------------------------------------------------------------------------

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = local.common_tags
}
