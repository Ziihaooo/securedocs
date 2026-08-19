# ---------------------------------------------------------------------------
# Kubernetes/Helm providers, authenticated against the cluster this same
# configuration creates.
#
# The `exec` block is the same mechanism `aws eks update-kubeconfig` writes into
# ~/.kube/config: shell out to the AWS CLI for a short-lived token rather than
# storing a credential. Terraform never holds a kubeconfig.
#
# CAVEAT worth knowing: these providers are configured from resources in this
# same state. On a FIRST apply Terraform resolves them lazily and it works, but
# if the cluster is ever destroyed outside Terraform the provider config becomes
# unresolvable and you get "Provider configuration is invalid" on plan. The
# clean fix at scale is a separate layer (L2) for cluster bootstrap. Kept here
# because there are only two charts.
# ---------------------------------------------------------------------------

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.region]
    }
  }
}

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.region]
  }
}
