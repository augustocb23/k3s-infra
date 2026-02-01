output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnets" {
  description = "List of IDs of public subnets"
  value       = aws_subnet.public[*].id
}

output "public_subnets_azs" {
  description = "List of Availability Zones for public subnets"
  value       = aws_subnet.public[*].availability_zone
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = aws_subnet.private[*].id
}

output "private_route_table_id" {
  description = "ID of the private route table, used to inject NAT route later"
  value       = aws_route_table.private.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}