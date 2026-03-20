# Network Configuration
aws_vpc_cidr       = "10.0.0.0/16"
aws_subnet_cidr    = "10.0.1.0/24"
aws_subnet_b_cidr  = "10.0.3.0/24"
aws_fw_subnet_cidr = "10.0.2.0/24"
aws_alb_subnet_a_cidr = "10.0.4.0/24"
aws_alb_subnet_b_cidr = "10.0.5.0/24"

# Workload Configuration
workload_ami_id        = ""                        # Set to Packer-built AMI ID (or leave blank for base RHEL)
workload_instance_type = "t3.xlarge"
workload_asg_min       = 2
workload_asg_desired   = 4
workload_asg_max       = 6

# Region
aws_region = "us-east-2"