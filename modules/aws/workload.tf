# ------------------------------------------------------------------
# Data source block to find the latest RHEL 10.1 AMI
# ------------------------------------------------------------------
data "aws_ami" "rhel" {
  most_recent = true

  filter {
    name   = "name"
    values = ["RHEL-10.1.0_HVM-*-x86_64-*-Hourly2-GP3"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["309956199498"] # Red Hat's AWS account ID
}

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
# Launch Template — RHEL 9 with Podman + systemd
# ------------------------------------------------------------------
resource "aws_launch_template" "workload" {
  name_prefix   = "workload-rhel-"
  image_id      = data.aws_ami.rhel.id
  instance_type = var.workload_instance_type
  user_data     = base64encode(file("${path.module}/scripts/user_data.sh"))

  # Standard mode: once burst credits are exhausted, CPU is throttled
  # to baseline (20% for t3.medium). This ensures sustained load
  # shows realistic CPU metrics for ASG scaling.
  credit_specification {
    cpu_credits = "standard"
  }

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
# Auto Scaling Group
# ------------------------------------------------------------------
resource "aws_autoscaling_group" "workload" {
  name                      = "workload-asg"
  min_size                  = var.workload_asg_min
  desired_capacity          = var.workload_asg_desired
  max_size                  = var.workload_asg_max
  vpc_zone_identifier       = [aws_subnet.workload.id, aws_subnet.workload_b.id]
  target_group_arns         = [aws_lb_target_group.workload.arn]
  health_check_type         = "ELB"
  wait_for_capacity_timeout = "0"

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
  name                          = "workload-tg"
  port                          = 80
  protocol                      = "HTTP"
  vpc_id                        = aws_vpc.main.id
  deregistration_delay          = 30
  load_balancing_algorithm_type = "round_robin"

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
# WAF — Web Application Firewall (defense in depth with ASAv)
# ------------------------------------------------------------------
resource "aws_wafv2_web_acl" "workload" {
  name        = "workload-waf"
  description = "WAF for workload ALB - dual-layer defense with Cisco ASAv"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # AWS Managed Rules — Common Rule Set (XSS, path traversal, etc.)
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rules — SQL Injection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesSQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rules — Known Bad Inputs (Log4j, SSRF, etc.)
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rules — Amazon IP Reputation List
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "workload-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

resource "aws_wafv2_web_acl_association" "workload" {
  resource_arn = aws_lb.workload.arn
  web_acl_arn  = aws_wafv2_web_acl.workload.arn
}

# ------------------------------------------------------------------
# ASG Auto Scaling Policies (Step Scaling)
# ------------------------------------------------------------------

# Scale-out policy: two steps based on CPU thresholds
# Tuned for t3.micro (10% baseline per vCPU after burst credits).
#   20% ≤ CPU < 35% → add 2 instances
#   CPU ≥ 35%        → add 4 instances (caps at max_size)
resource "aws_autoscaling_policy" "cpu_scale_out" {
  name                   = "workload-cpu-scale-out"
  autoscaling_group_name = aws_autoscaling_group.workload.name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"
  metric_aggregation_type = "Average"

  step_adjustment {
    metric_interval_lower_bound = 0
    metric_interval_upper_bound = 15
    scaling_adjustment          = 2
  }

  step_adjustment {
    metric_interval_lower_bound = 15
    scaling_adjustment          = 4
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "workload-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 20
  alarm_description   = "Scale out when ASG average CPU >= 20%"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.workload.name
  }

  alarm_actions = [aws_autoscaling_policy.cpu_scale_out.arn]
}

# Scale-in policy: remove 1 instance when CPU drops below 10%
resource "aws_autoscaling_policy" "cpu_scale_in" {
  name                   = "workload-cpu-scale-in"
  autoscaling_group_name = aws_autoscaling_group.workload.name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"
  metric_aggregation_type = "Average"

  step_adjustment {
    metric_interval_upper_bound = 0
    scaling_adjustment          = -1
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "workload-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 10
  alarm_description   = "Scale in when ASG average CPU < 10%"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.workload.name
  }

  alarm_actions = [aws_autoscaling_policy.cpu_scale_in.arn]
}
