# ---------------------------------------------------------------------------
# ingress-nginx.
#
# Bootstrap infrastructure, like the ALB controller: without an ingress
# controller no Ingress object does anything, so the cluster cannot serve
# traffic until this exists. That is the test for "belongs in Terraform".
#
# Chosen over using the ALB controller directly because the same Ingress
# manifests must also run on AKS in Phase 6. `ingressClassName: alb` is
# meaningless on Azure; `nginx` is not.
#
# Depends on the ALB controller: the Service below is type LoadBalancer, and
# the ALB controller is what turns that into a real NLB. Install them in the
# wrong order and the Service sits at <pending> forever.
# ---------------------------------------------------------------------------

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true

  # Pinned, same reasoning as the ALB controller.
  version = "4.11.3"

  values = [file("${path.module}/../../helm/ingress-nginx-values-eks.yaml")]

  # NOT --wait. On kind, `--wait` timing out meant Helm skipped its post-install
  # hooks and the admission webhook's caBundle was never populated, so every
  # Ingress create failed with "x509: certificate signed by unknown authority".
  # Terraform's helm provider waits by default; a longer timeout is safer than
  # a short one, because provisioning an NLB takes a few minutes.
  timeout = 900

  depends_on = [
    helm_release.alb_controller,
    aws_eks_node_group.default,
  ]
}

# Reads back the Service the nginx chart created, to find the NLB's DNS name.
data "kubernetes_service" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }

  depends_on = [helm_release.ingress_nginx]
}

output "nlb_hostname" {
  description = "Public DNS name of the NLB. Browse here, or CNAME your domain to it."
  value       = try(data.kubernetes_service.ingress_nginx.status[0].load_balancer[0].ingress[0].hostname, "pending")
}
