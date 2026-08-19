# Consumed by L1 via terraform_remote_state.
# Anything not exported here is invisible to L1, even though it exists in state.

output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

# L1 adds the NAT route into this table.
output "private_route_table_id" {
  value = aws_route_table.private.id
}

# L1's NAT gateway depends on the IGW existing.
output "internet_gateway_id" {
  value = aws_internet_gateway.this.id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.api.repository_url
}

output "cluster_name" {
  description = "Name L1 must use, so the subnet tags match"
  value       = local.cluster_name
}
