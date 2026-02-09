# AWS Infrastructure — VPC, Subnets, ECS Cluster, Firewall Subnet
# The Cisco ASAv firewall is deployed separately via AWS CLI ASG.
module "aws" {
  source = "./modules/aws"

  region                 = var.aws_region
  vpc_cidr               = var.aws_vpc_cidr
  workload_subnet_cidr   = var.aws_subnet_cidr
  workload_subnet_b_cidr = var.aws_subnet_b_cidr
  firewall_subnet_cidr   = var.aws_fw_subnet_cidr
  alb_subnet_a_cidr      = var.aws_alb_subnet_a_cidr
  alb_subnet_b_cidr      = var.aws_alb_subnet_b_cidr
  ecs_instance_type      = var.ecs_instance_type
  ecs_asg_min            = var.ecs_asg_min
  ecs_asg_desired        = var.ecs_asg_desired
  ecs_asg_max            = var.ecs_asg_max
  tags                   = var.tags
}
