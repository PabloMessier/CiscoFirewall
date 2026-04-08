# ------------------------------------------------------------------
# Workload — RHEL EC2 instances running nginx via Podman + systemd
# Golden AMI built by Packer is fully self-contained (no user data).
# ------------------------------------------------------------------

# ------------------------------------------------------------------
# IAM — Instance Role (SSM access only)
# ------------------------------------------------------------------
resource "aws_iam_role" "workload_instance" {
  name = "workload-instance-role"

  assume_role_policy = file("${path.module}/json/workload_assume_role.json")

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "workload_ssm" {
  role       = aws_iam_role.workload_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "workload_instance" {
  name = "workload-instance-profile"
  role = aws_iam_role.workload_instance.name
}

# ------------------------------------------------------------------
# Security Groups — ALB and Workload Instances
# ------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "workload-alb-sg"
  description = "Security group for workload ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "Workload-ALB-SG"
  })
}

resource "aws_security_group" "workload_instances" {
  name        = "workload-instances-sg"
  description = "Security group for workload RHEL instances"
  vpc_id      = aws_vpc.main.id

  # HTTP from ALB (Podman maps host:80 → container:80)
  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # HTTP from NLB (TCP passthrough — NLB preserves client source IP)
  ingress {
    description = "HTTP via NLB"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH for debugging
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ICMP for ping testing
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
    Name = "Workload-Instances-SG"
  })
}

# ------------------------------------------------------------------
# Launch Template — RHEL 10.1 with Podman + systemd
# ------------------------------------------------------------------
resource "aws_launch_template" "workload" {
  name_prefix   = "workload-rhel-"
  image_id      = var.workload_ami_id
  instance_type = var.workload_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.workload_instance.arn
  }

  vpc_security_group_ids = [aws_security_group.workload_instances.id]

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "Workload RHEL Instance"
    })
  }

  tags = var.tags

  depends_on = [
    aws_iam_instance_profile.workload_instance
  ]
}

# ------------------------------------------------------------------
# Auto Scaling Group
# ------------------------------------------------------------------
resource "aws_autoscaling_group" "workload" {
  name                = "workload-asg"
  min_size            = var.workload_asg_min
  desired_capacity    = var.workload_asg_desired
  max_size            = var.workload_asg_max
  vpc_zone_identifier = [aws_subnet.workload.id, aws_subnet.workload_b.id]
  target_group_arns   = [aws_lb_target_group.workload.arn]
  health_check_type   = "ELB"

  launch_template {
    id      = aws_launch_template.workload.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "Workload RHEL Instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_launch_template.workload,
    aws_route_table_association.workload,
    aws_route_table_association.workload_b
  ]
}

# ------------------------------------------------------------------
# ALB — Application Load Balancer
# ------------------------------------------------------------------
resource "aws_lb" "workload" {
  name               = "workload-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.alb_a.id, aws_subnet.alb_b.id]

  tags = merge(var.tags, {
    Name = "Workload ALB"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_lb_target_group" "workload" {
  name                 = "workload-tg"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = "/"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = var.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.workload.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.workload.arn
  }
}

# ------------------------------------------------------------------
# NLB — Network Load Balancer (TCP passthrough for stress testing)
# ------------------------------------------------------------------
resource "aws_lb" "workload_nlb" {
  name               = "workload-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [aws_subnet.alb_a.id, aws_subnet.alb_b.id]

  tags = merge(var.tags, {
    Name = "Workload NLB"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_lb_target_group" "workload_nlb" {
  name                          = "workload-nlb-tg"
  port                          = 80
  protocol                      = "TCP"
  vpc_id                        = aws_vpc.main.id
  deregistration_delay          = 30
  preserve_client_ip            = false  # Prevents asymmetric routing through firewall

  health_check {
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = var.tags
}

resource "aws_lb_listener" "nlb_tcp" {
  load_balancer_arn = aws_lb.workload_nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.workload_nlb.arn
  }
}

resource "aws_autoscaling_attachment" "nlb" {
  autoscaling_group_name = aws_autoscaling_group.workload.name
  lb_target_group_arn    = aws_lb_target_group.workload_nlb.arn
}

# ------------------------------------------------------------------
# ASG Auto Scaling Policies
# ------------------------------------------------------------------

# Scale based on average CPU utilisation (single policy for ~5 min scale-in)
resource "aws_autoscaling_policy" "cpu" {
  name                      = "workload-cpu-scaling"
  autoscaling_group_name    = aws_autoscaling_group.workload.name
  policy_type               = "TargetTrackingScaling"
  estimated_instance_warmup = 120

  target_tracking_configuration {
    target_value = 70

    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
  }
}
