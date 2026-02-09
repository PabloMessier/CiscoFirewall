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

# ECS Configuration
variable "ecs_instance_type" {
  description = "EC2 instance type for ECS container instances"
  type        = string
}

variable "ecs_asg_min" {
  description = "Minimum number of ECS instances in ASG"
  type        = number
}

variable "ecs_asg_desired" {
  description = "Desired number of ECS instances in ASG"
  type        = number
}

variable "ecs_asg_max" {
  description = "Maximum number of ECS instances in ASG"
  type        = number
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
