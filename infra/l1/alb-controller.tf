# ---------------------------------------------------------------------------
# IRSA for the AWS Load Balancer Controller.
#
# This is the first real use of the OIDC provider created in eks.tf, and it is
# the complete IRSA pattern:
#
#   1. an IAM policy       what it may do in AWS
#   2. an IAM role         trusted by the cluster's OIDC provider, restricted
#                          to ONE ServiceAccount
#   3. the annotation      (applied at helm install time, not here)
#
# Same shape as the Bitbucket -> AWS federation, with the cluster as the
# identity provider instead of a CI system.
# ---------------------------------------------------------------------------

locals {
  # Strip "https://" — IAM condition keys use the bare host+path form.
  oidc_issuer_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")

  alb_namespace       = "kube-system"
  alb_service_account = "aws-load-balancer-controller"
}

# Published by AWS, vendored into the repo.
#
# ⚠ THE POLICY VERSION MUST MATCH THE CONTROLLER VERSION.
#
#   helm chart 1.9.2  →  controller image v2.9.2  →  policy from tag v2.9.2
#
#   curl -o alb-controller-policy.json \
#     https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.9.2/docs/install/iam_policy.json
#
# We got this wrong once: chart 1.9.2 with the v2.8.2 policy. The controller
# came up fine, IRSA worked, and then every reconcile failed with:
#
#   AccessDenied: not authorized to perform:
#   elasticloadbalancing:DescribeListenerAttributes
#
# — a permission added in v2.9.0. The Service sat at <pending> for 21 minutes
# and the helm release timed out. Nothing in the Terraform or the Helm output
# said why; the answer was only in the controller's own logs.
#
# Roughly 40 permissions: elasticloadbalancing:*, ec2:Describe*, acm:*, wafv2,
# shield. Never hand-write it.
resource "aws_iam_policy" "alb_controller" {
  name        = "${local.cluster_name}-alb-controller"
  description = "AWS Load Balancer Controller — from the upstream published policy"
  policy      = file("${path.module}/alb-controller-policy.json")

  tags = local.common_tags
}

resource "aws_iam_role" "alb_controller" {
  name = "${local.cluster_name}-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        # NOT a service. A federated identity provider — the cluster itself.
        Federated = aws_iam_openid_connect_provider.this.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"

      Condition = {
        StringEquals = {
          # THE line that makes IRSA safe. Without this condition, ANY
          # ServiceAccount in the cluster could assume this role and create
          # load balancers. With it, exactly one can.
          "${local.oidc_issuer_host}:sub" = "system:serviceaccount:${local.alb_namespace}:${local.alb_service_account}"

          # The audience. Prevents a token minted for something else being
          # replayed against STS.
          "${local.oidc_issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

output "alb_controller_role_arn" {
  value = aws_iam_role.alb_controller.arn
}

# ---------------------------------------------------------------------------
# The controller itself.
#
# In Terraform rather than a manual `helm install`, because this is BOOTSTRAP
# infrastructure: without it no Ingress can ever produce a load balancer, so
# the cluster is not usable until it exists. A cluster that needs a remembered
# command after `terraform apply` is not reproducible.
#
# The dividing line:
#   terraform  cluster + the few charts required before anything can deploy
#   ArgoCD     every application, from git
#
# Same chicken-and-egg as argocd/web-application.yaml being hand-applied —
# something has to come first.
# ---------------------------------------------------------------------------

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  # Pinned. An unpinned chart means `terraform apply` can install a different
  # version next month and change behaviour with no diff in your code.
  version = "1.9.2"

  # Values live in a file so they are reviewable in git, rather than a wall of
  # `set` blocks. Same reasoning as helm/ingress-nginx-values.yaml.
  values = [file("${path.module}/../../helm/alb-controller-values.yaml")]

  # Chart values are static text; the role ARN is only known after apply.
  # `set` fills in what the file cannot.
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller.arn
  }

  depends_on = [
    # Without nodes the pods stay Pending and the release never becomes ready.
    aws_eks_node_group.default,
    aws_iam_role_policy_attachment.alb_controller,

    # Destroy ordering: this controller must still have internet egress while
    # it cleans up the AWS resources it created. See the longer note in
    # ingress-nginx.tf.
    aws_route.private_nat,
  ]
}
