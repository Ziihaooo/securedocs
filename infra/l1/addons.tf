# ---------------------------------------------------------------------------
# EKS managed add-ons.
#
# These three run IN the cluster but are AWS-managed: it patches them, tracks
# compatible versions per Kubernetes release, and upgrades them on request.
# You could install them yourself with Helm — managed means one less thing to
# maintain, and version compatibility is guaranteed.
#
# They are the components kind gave you for free. On kind these were kindnet
# and CoreDNS, installed by `kind create cluster`. On EKS you ask for them.
# ---------------------------------------------------------------------------

# Pod networking. Assigns every pod a REAL VPC IP from the node's ENIs —
# not an overlay network like kind's. That is why subnet sizing matters:
# pods consume VPC addresses.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"

  # If the addon and your Terraform disagree about config, Terraform wins.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags
}

# Implements Services: the iptables/IPVS rules that make a ClusterIP work.
# Without it, Services resolve but connections go nowhere.
resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags
}

# Cluster DNS. This is what resolves "postgres" to a ClusterIP.
#
# Runs as PODS, so it needs nodes to exist — hence the depends_on. Without it
# the addon is created while there are no nodes, sits Degraded, and every DNS
# lookup in the cluster fails.
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags

  depends_on = [aws_eks_node_group.default]
}
