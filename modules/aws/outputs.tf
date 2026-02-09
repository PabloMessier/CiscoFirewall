# Network
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.main.id
}

# Subnets
output "firewall_subnet_id" {
  description = "Firewall subnet ID (for Cisco ASAv deployment via AWS CLI ASG)"
  value       = aws_subnet.firewall.id
}

output "workload_subnet_ids" {
  description = "Workload subnet IDs"
  value       = [aws_subnet.workload.id, aws_subnet.workload_b.id]
}

# Firewall
output "firewall_security_group_id" {
  description = "Firewall security group ID (attach to Cisco ASAv via AWS CLI)"
  value       = aws_security_group.firewall.id
}

# ECS
output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN"
  value       = aws_ecs_cluster.main.arn
}

output "alb_dns_name" {
  description = "ALB DNS name for the Hello World ECS service"
  value       = aws_lb.ecs.dns_name
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.ecs.arn
}
