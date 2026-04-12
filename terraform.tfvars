# Network Configuration
aws_vpc_cidr               = "10.0.0.0/20"
aws_fw_subnet_cidr         = "10.0.1.0/28"
aws_inside_eni_subnet_cidr = "10.0.2.0/28"
aws_alb_subnet_a_cidr      = "10.0.3.0/27"
aws_alb_subnet_b_cidr      = "10.0.4.0/27"
aws_workload_subnet_a_cidr = "10.0.5.0/26"
aws_workload_subnet_b_cidr = "10.0.6.0/26"

# Workload Configuration
workload_instance_type = "t3.micro"
workload_asg_min       = 2
workload_asg_desired   = 4
workload_asg_max       = 6

# Region
aws_region = "us-east-2"