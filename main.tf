# AWS Infrastructure — VPC, Subnets, Workload ASG, Firewall Subnet
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
  workload_ami_id        = var.workload_ami_id
  workload_instance_type = var.workload_instance_type
  workload_asg_min       = var.workload_asg_min
  workload_asg_desired   = var.workload_asg_desired
  workload_asg_max       = var.workload_asg_max
  tags                   = var.tags
}