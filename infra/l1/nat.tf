provider "aws" {
  region = var.region
}

locals {
  environment  = terraform.workspace
  l0           = data.terraform_remote_state.l0.outputs
  cluster_name = local.l0.cluster_name

  common_tags = {
    Project     = "SecureDocs"
    Environment = local.environment
    Tier        = "L1"
    ManagedBy   = "terraform"
  }
}

check "correct_account" {
  assert {
    condition     = data.aws_caller_identity.current.account_id != "314146318322"
    error_message = "Pointed at the AceArena work account. Wrong AWS profile."
  }
}

# ---------------------------------------------------------------------------
# NAT gateway — the single most expensive idle resource here (~$32/month plus
# data transfer). It lives in L1 precisely so `terraform destroy` removes it.
#
# ONE gateway, not one per AZ. A production setup would use one per AZ so an AZ
# outage doesn't take out egress for the others — that is 3x the cost for
# resilience this environment does not need.
# ---------------------------------------------------------------------------

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.cluster_name}-nat" })
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = local.l0.public_subnet_ids[0]

  tags = merge(local.common_tags, { Name = "${local.cluster_name}-nat" })

  # No depends_on for the IGW. It lives in L0's state, not this configuration,
  # so Terraform cannot order against it — depends_on only accepts whole
  # resources in the SAME config. It doesn't need to: L0 is applied first and
  # separately, so the IGW already exists by the time L1 runs. Layer ordering
  # is enforced by the pipeline, not by the dependency graph.
}

# Injects egress into the route table L0 created EMPTY. Destroying L1 removes
# this route with the gateway, leaving L0's table intact and valid.
resource "aws_route" "private_nat" {
  route_table_id         = local.l0.private_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}
