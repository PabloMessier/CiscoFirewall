variable "aws_region" {
  description = "AWS region for resources"
  type        = string
}

# Network Configuration
variable "aws_vpc_cidr" {
  description = "CIDR block for AWS VPC"
  type        = string
}

variable "aws_fw_subnet_cidr" {
  description = "CIDR block for AWS firewall subnet"
  type        = string
}

variable "aws_alb_subnet_a_cidr" {
  description = "CIDR block for ALB public subnet A"
  type        = string
}

variable "aws_alb_subnet_b_cidr" {
  description = "CIDR block for ALB public subnet B"
  type        = string
}

variable "aws_workload_subnet_a_cidr" {
  description = "CIDR block for AWS workload subnet A"
  type        = string
}

variable "aws_workload_subnet_b_cidr" {
  description = "CIDR block for AWS workload subnet B (second AZ for ALB)"
  type        = string
}

variable "aws_inside_eni_subnet_cidr" {
  description = "CIDR block for AWS inside ENI subnet (must be /28 or smaller)"
  type        = string
}

# Workload Configuration
variable "workload_instance_type" {
  description = "EC2 instance type for workload RHEL instances"
  type        = string
}

variable "workload_asg_min" {
  description = "Minimum number of workload instances in ASG"
  type        = number
}

variable "workload_asg_desired" {
  description = "Desired number of workload instances in ASG"
  type        = number
}

variable "workload_asg_max" {
  description = "Maximum number of workload instances in ASG"
  type        = number
}

# Resource Tagging
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Development"
    Project     = "CiscoFirewall-Infrastructure"
    ManagedBy   = "Terraform"
  }
}
