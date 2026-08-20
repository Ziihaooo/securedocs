# ---------------------------------------------------------------------------
# cert-manager.
#
# Turns a TLS certificate into a Kubernetes object. You declare "this Ingress
# needs a cert for this hostname"; a controller talks to Let's Encrypt, proves
# you control the name, stores the result in a Secret, and renews it before it
# expires. No openssl, no calendar reminder, no manual upload.
#
# Why not AWS Certificate Manager:
#   ACM certs can only be attached to AWS things (ALB, CloudFront, API GW).
#   Our TLS terminates at ingress-nginx, inside the cluster. Same reason we
#   chose ingress-nginx over the ALB controller on Day 9 - this all runs
#   unchanged on AKS in Phase 6.
#
# No IRSA here. HTTP-01 validation proves control by serving a file over port
# 80, which needs no AWS permissions at all. (DNS-01 with Route53 would need
# IRSA - that is the upgrade path if we ever buy a domain.)
# ---------------------------------------------------------------------------

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = "v1.16.2"

  # cert-manager ships CRDs (ClusterIssuer, Certificate, CertificateRequest,
  # Order, Challenge). Off by default in this chart because the CRDs outlive
  # the release; we install them with it so a destroy cleans up fully.
  set {
    name  = "crds.enabled"
    value = "true"
  }

  timeout = 600

  depends_on = [
    aws_eks_node_group.default,

    # NOT because cert-manager uses the ALB controller — it does not.
    #
    # The ALB controller registers a MutatingWebhookConfiguration that
    # intercepts every Service created anywhere in the cluster, with
    # failurePolicy: Fail. Until its pods have endpoints, creating any Service
    # returns "no endpoints available for service
    # aws-load-balancer-webhook-service" and the release dies.
    #
    # helm_release waits for readiness, so depending on it removes the race.
    helm_release.alb_controller,

    aws_route.private_nat,
  ]
}
