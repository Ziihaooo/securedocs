variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-2"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "availability_zones" {
  description = "AZs to spread subnets across. Two minimum — EKS requires the control plane in at least two."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "EKS requires at least two availability zones."
  }
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs, one per AZ. Hosts the ALB and NAT gateway."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs, one per AZ. Hosts the EKS nodes and pods."
  type        = list(string)
}

# ── CI ──────────────────────────────────────────────────────────────────────
# Which repository and branch may assume the GitHub Actions role. Variables
# rather than literals so a release branch or a second repo is a tfvars change.
variable "github_repo" {
  description = "Repository identity exactly as it appears in the OIDC sub claim"
  type        = string

  # NOT plain "owner/name". This repository's tokens embed the numeric owner
  # and repository IDs. Verify with the diagnostic step in ci.yml, which
  # decodes the token and prints the claim - never assume the documented shape.
  default = "Ziihaooo@137987948/securedocs@1331597756"
}

variable "github_branch" {
  description = "Branch allowed to push images. Must be the branch ArgoCD tracks."
  type        = string
  default     = "argocd"
}
