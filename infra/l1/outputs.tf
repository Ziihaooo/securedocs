output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "The API server URL kubectl talks to"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "oidc_provider_arn" {
  description = "Referenced by IRSA role trust policies (Day 13)"
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "Used in the sub/aud conditions of IRSA trust policies"
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "nat_public_ip" {
  description = "The address all cluster egress appears to come from — allowlist this with third parties"
  value       = aws_eip.nat.public_ip
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.this.name}"
}
