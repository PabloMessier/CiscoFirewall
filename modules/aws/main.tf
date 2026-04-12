resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "AWS VPC"
  })
}

# Workload subnets (two AZs required for ALB)
resource "aws_subnet" "workload" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.workload_subnet_a_cidr
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "AWS Workload Subnet A"
  })
}

resource "aws_subnet" "workload_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.workload_subnet_b_cidr
  availability_zone       = "${var.region}b"
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "AWS Workload Subnet B"
  })
}

# ALB public subnets (separate from workload so ALB keeps IGW route
# even when workload subnets route through the firewall)
resource "aws_subnet" "alb_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.alb_subnet_a_cidr
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "AWS ALB Subnet A"
  })
}

resource "aws_subnet" "alb_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.alb_subnet_b_cidr
  availability_zone       = "${var.region}b"
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "AWS ALB Subnet B"
  })
}

# Firewall inspection subnet
resource "aws_subnet" "firewall" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.firewall_subnet_cidr
  availability_zone = "${var.region}a"

  tags = merge(var.tags, {
    Name = "AWS Firewall Subnet"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "AWS Internet Gateway"
  })
}

# Route tables and security groups defined in firewall.tf and workload.tf
# Inside ENI resource
resource "aws_subnet" "inside_eni" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.inside_eni_subnet_cidr
  availability_zone = "${var.region}a"  # Must match firewall subnet AZ for ENI attachment

  tags = merge(var.tags, {
    Name = "AWS Inside ENI Subnet"
  })
}