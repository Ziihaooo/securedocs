variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-2"
}

variable "kubernetes_version" {
  description = "EKS control plane version. AWS supports ~4 versions; upgrades are one minor at a time."
  type        = string
  default     = "1.31"
}

variable "api_public_access_cidrs" {
  description = <<-EOT
    Who may REACH the API endpoint. They still need valid credentials to do
    anything. Production restricts this to office/VPN ranges; a home IP changes,
    so locking it down here risks locking yourself out.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_log_types" {
  description = <<-EOT
    Control-plane logs sent to CloudWatch. "audit" is the only record of who did
    what in the cluster. Costs CloudWatch ingestion — set to [] to disable.
  EOT
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

# ── node group ──────────────────────────────────────────────────────────────

variable "node_instance_types" {
  description = <<-EOT
    Instance type also caps POD DENSITY, not just CPU. The VPC CNI assigns each
    pod a real VPC IP from the node's ENIs:
      t3.small  ~11 pods
      t3.medium ~17 pods
      t3.large  ~35 pods
    Hitting the pod limit before the CPU limit is the usual EKS surprise.
  EOT
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT. SPOT is ~70% cheaper and can be reclaimed with 2 minutes' notice."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "Must be ON_DEMAND or SPOT."
  }
}

variable "node_disk_size" {
  description = "EBS volume size per node (GB). Holds container images, logs and ephemeral storage."
  type        = number
  default     = 20
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 3
}

# ── git source for ArgoCD ───────────────────────────────────────────────────
# Which repository and branch the cluster follows. ArgoCD pulls from here; no
# credentials needed while the repo is public.
variable "repo_url" {
  description = "Git repository ArgoCD syncs from"
  type        = string
  default     = "https://github.com/Ziihaooo/securedocs.git"
}

variable "repo_revision" {
  description = "Branch or tag ArgoCD tracks"
  type        = string
  default     = "argocd"
}
