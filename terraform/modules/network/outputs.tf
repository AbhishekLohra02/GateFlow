output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, one per availability zone."
  value       = aws_subnet.public[*].id
}

output "security_group_id" {
  description = "Security group to attach to ECS container instances."
  value       = aws_security_group.instance.id
}

output "availability_zones" {
  description = "AZs the subnets were placed in."
  value       = aws_subnet.public[*].availability_zone
}
