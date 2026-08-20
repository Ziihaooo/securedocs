# ---------------------------------------------------------------------------
# EBS CSI driver — what makes PersistentVolumeClaims work on EKS.
#
# kind installed rancher local-path automatically, so PVCs bound instantly.
# EKS ships NO storage driver. Without this, postgres's PVC sits Pending
# forever with "no persistent volumes available for this claim", and the
# StatefulSet never starts.
#
# Second IRSA example, and deliberately simpler than the ALB controller:
#   policy   AWS-managed (AmazonEBSCSIDriverPolicy) — nothing to download or
#            version-match, unlike the ALB controller's vendored JSON
#   install  aws_eks_addon rather than helm_release — AWS tracks which driver
#            version is compatible with your Kubernetes version
# ---------------------------------------------------------------------------

locals {
  ebs_csi_namespace       = "kube-system"
  ebs_csi_service_account = "ebs-csi-controller-sa"
}

resource "aws_iam_role" "ebs_csi" {
  name = "${local.cluster_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.this.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # The ServiceAccount name is fixed by the addon — you do not choose
          # it. Get it wrong and the driver authenticates as nothing and every
          # volume operation fails with AccessDenied.
          "${local.oidc_issuer_host}:sub" = "system:serviceaccount:${local.ebs_csi_namespace}:${local.ebs_csi_service_account}"
          "${local.oidc_issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

# AWS-managed, so it stays correct as the driver adds features.
# Grants CreateVolume, AttachVolume, DeleteVolume, CreateSnapshot and friends.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "aws-ebs-csi-driver"

  # Wires IRSA without an annotation — the addon creates the ServiceAccount
  # itself and annotates it with this ARN.
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags

  # The controller runs as pods, so it needs nodes. Same reason coredns has it.
  depends_on = [
    aws_eks_node_group.default,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}

# ---------------------------------------------------------------------------
# StorageClass.
#
# EKS creates a default "gp2" StorageClass, but gp2 is the previous generation:
# slower baseline, and its throughput is tied to volume size. gp3 is cheaper
# per GB and gives 3000 IOPS at any size.
#
# Declared here rather than left to the default so the choice is explicit and
# the chart does not have to name a class at all.
# ---------------------------------------------------------------------------

# EKS ships only a "gp2" StorageClass, and gp2 is the previous generation:
# IOPS are tied to volume size (3 per GB), so a 10Gi volume gets 30 IOPS. gp3
# gives 3000 IOPS at any size and is ~20% cheaper per GB. There is no case
# where gp2 is the better choice — it is default only for backwards
# compatibility.
#
# gp3 is NOT marked as the default here. The chart names it explicitly via
# `postgres.storageClass`, for two reasons:
#
#   1. explicit beats implicit — which class a PVC got is readable from the
#      chart, not dependent on cluster state
#   2. it avoids editing gp2, an object EKS owns. Marking gp3 default would
#      require demoting gp2 first (two defaults is an error state), which means
#      forcing ownership of a field another controller manages
#
# The class name differs per cluster (kind: "standard", EKS: "gp3"), so it is
# a chart value — same pattern as ingress.className.
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
  }

  storage_provisioner = "ebs.csi.aws.com"

  # Delete the PVC and the EBS volume goes with it. Same as kind's default —
  # and the same footgun: `kubectl delete pvc` is data loss, not tidying up.
  reclaim_policy = "Delete"

  # Do not create the volume until a pod is scheduled. An EBS volume lives in
  # ONE availability zone; provisioning it before knowing the pod's AZ can
  # strand the volume where the pod cannot reach it.
  volume_binding_mode = "WaitForFirstConsumer"

  # Lets you grow a volume without recreating it.
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}
