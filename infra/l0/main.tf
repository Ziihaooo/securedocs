provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  environment  = terraform.workspace
  cluster_name = "securedocs-${local.environment}"

  common_tags = {
    Project     = "SecureDocs"
    Environment = local.environment
    Tier        = "L0"
    ManagedBy   = "terraform"
  }

  # Every subnet needs this so EKS and the ALB controller recognise them as
  # belonging to the cluster. "shared" (rather than "owned") means the VPC
  # outlives the cluster — which is the entire point of the L0/L1 split.
  cluster_tag = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

# Guard: this must never run against the old AceArena work account.
check "correct_account" {
  assert {
    condition     = data.aws_caller_identity.current.account_id != "314146318322"
    error_message = "Pointed at the AceArena work account. Wrong AWS profile."
  }
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both required by EKS. Nodes register with the cluster by DNS name, and
  # without these the kubelet cannot resolve the API endpoint.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "securedocs-${local.environment}" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "securedocs-${local.environment}-igw" })
}

# ---------------------------------------------------------------------------
# Subnets
#
# /24 = 251 usable IPs each. Sized for PODS, not nodes: the VPC CNI gives every
# pod a real VPC IP, so a t3.medium can consume ~17 addresses on its own. A /24
# runs out of IPs long before it runs out of CPU — the classic EKS surprise.
# ---------------------------------------------------------------------------

resource "aws_subnet" "public" {
  for_each = { for i, az in var.availability_zones : az => i }

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = var.public_subnet_cidrs[each.value]
  map_public_ip_on_launch = true

  tags = merge(
    local.common_tags,
    local.cluster_tag,
    {
      Name = "securedocs-${local.environment}-public-${each.key}"
      # Tells the AWS Load Balancer Controller it may create INTERNET-FACING
      # load balancers here. Without this tag it finds no subnets and fails
      # SILENTLY — no ALB, no useful error.
      "kubernetes.io/role/elb" = "1"
    }
  )
}

resource "aws_subnet" "private" {
  for_each = { for i, az in var.availability_zones : az => i }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = var.private_subnet_cidrs[each.value]

  tags = merge(
    local.common_tags,
    local.cluster_tag,
    {
      Name = "securedocs-${local.environment}-private-${each.key}"
      # Same, for INTERNAL load balancers.
      "kubernetes.io/role/internal-elb" = "1"
    }
  )
}

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.common_tags, { Name = "securedocs-${local.environment}-public" })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Created EMPTY on purpose. L1 injects the 0.0.0.0/0 -> NAT route, so destroying
# L1 removes the cluster's egress AND its cost, leaving this VPC intact and
# valid. Same pattern as AceArena.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "securedocs-${local.environment}-private" })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# ECR — in L0 so images survive every L1 destroy
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "api" {
  name = "securedocs-api"

  # Tags can be overwritten by default, which makes them meaningless as a
  # record of what shipped. IMMUTABLE means v1.0.0 always refers to the same
  # bytes — a prerequisite for the cosign signing in Week 3.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

# Untagged images accumulate on every rebuild and are billed for.
resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the 20 most recent tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}
