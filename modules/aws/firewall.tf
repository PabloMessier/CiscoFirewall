# ------------------------------------------------------------------
# Firewall Security Group
# Used by the Cisco ASAv instance deployed via AWS CLI ASG.
# Allows Ansible management (SSH) and inspection traffic (HTTP/HTTPS/ICMP).
# ------------------------------------------------------------------
resource "aws_security_group" "firewall" {
  name        = "cisco-asav-firewall-sg"
  description = "Security group for Cisco ASAv firewall appliance"
  vpc_id      = aws_vpc.main.id

  # SSH - Ansible configuration
  ingress {
    description = "SSH for Ansible"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP - inbound traffic for firewall inspection
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS - inbound traffic for firewall inspection
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ICMP - inspection traffic and ping testing
  ingress {
    description = "ICMP"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "Cisco-ASAv-Firewall-SG"
  })

  # Ensure VPC is fully created before SG, and SG is destroyed before VPC
  depends_on = [aws_vpc.main]
}

# ------------------------------------------------------------------
# Route Tables
# ------------------------------------------------------------------

# Route table for firewall subnet (internet access)
resource "aws_route_table" "firewall" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "AWS Firewall Route Table"
  })

  # Ensure IGW is ready; on destroy, route table removed before IGW
  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table_association" "firewall" {
  subnet_id      = aws_subnet.firewall.id
  route_table_id = aws_route_table.firewall.id

  depends_on = [
    aws_subnet.firewall,
    aws_route_table.firewall
  ]
}

# Route table for ALB subnets (always routes to IGW)
resource "aws_route_table" "alb" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "AWS ALB Route Table"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table_association" "alb_a" {
  subnet_id      = aws_subnet.alb_a.id
  route_table_id = aws_route_table.alb.id
}

resource "aws_route_table_association" "alb_b" {
  subnet_id      = aws_subnet.alb_b.id
  route_table_id = aws_route_table.alb.id
}

# Route table for workload subnet
# NOTE: Currently routes directly to IGW. After Cisco ASAv is deployed
# via AWS CLI ASG, update the default route to point to the firewall
# ENI so all outbound traffic is inspected.
resource "aws_route_table" "workload" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "AWS Workload Route Table"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table_association" "workload" {
  subnet_id      = aws_subnet.workload.id
  route_table_id = aws_route_table.workload.id

  depends_on = [
    aws_subnet.workload,
    aws_route_table.workload
  ]
}

resource "aws_route_table_association" "workload_b" {
  subnet_id      = aws_subnet.workload_b.id
  route_table_id = aws_route_table.workload.id

  depends_on = [
    aws_subnet.workload_b,
    aws_route_table.workload
  ]
}
