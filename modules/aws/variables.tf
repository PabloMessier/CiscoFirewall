variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
}

variable "workload_subnet_cidr" {
  description = "CIDR block for workload subnet A"
  type        = string
}

variable "workload_subnet_b_cidr" {
  description = "CIDR block for workload subnet B (second AZ for ALB)"
  type        = string
}

variable "firewall_subnet_cidr" {
  description = "CIDR block for firewall subnet"
  type        = string
}

variable "alb_subnet_a_cidr" {
  description = "CIDR block for ALB public subnet A"
  type        = string
}

variable "alb_subnet_b_cidr" {
  description = "CIDR block for ALB public subnet B"
  type        = string
}

# Workload Configuration
variable "workload_ami_id" {
  description = "Packer-built golden AMI ID for workload instances (required — run packer build first)."
  type        = string
}

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

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
