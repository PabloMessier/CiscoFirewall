# Network
output "aws_vpc_id" {
  description = "AWS VPC ID"
  value       = module.aws.vpc_id
}

output "aws_vpc_cidr" {
  description = "AWS VPC CIDR block"
  value       = module.aws.vpc_cidr
}

# Firewall — use these when deploying Cisco ASAv via AWS CLI
output "aws_firewall_subnet_id" {
  description = "Firewall Subnet ID (for Cisco ASAv deployment via AWS CLI ASG)"
  value       = module.aws.firewall_subnet_id
}

output "aws_firewall_security_group_id" {
  description = "Firewall Security Group ID (attach to Cisco ASAv via AWS CLI)"
  value       = module.aws.firewall_security_group_id
}

# Workload
output "alb_dns_name" {
  description = "ALB DNS name — Hello World test page"
  value       = module.aws.alb_dns_name
}

output "nlb_dns_name" {
  description = "NLB DNS name — stress testing endpoint"
  value       = module.aws.nlb_dns_name
}
