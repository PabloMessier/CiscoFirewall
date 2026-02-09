# ------------------------------------------------------------------
# ECS Cluster — EC2 launch type with ASG for stress-testing firewall
# ------------------------------------------------------------------

# ECS-optimized Amazon Linux 2 AMI
data "aws_ami" "ecs_optimized" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-*-x86_64-ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_ecs_cluster" "main" {
  name = "workload-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.tags, {
    Name = "ECS Workload Cluster"
  })
}

# ------------------------------------------------------------------
# IAM — ECS Instance Role
# ------------------------------------------------------------------
resource "aws_iam_role" "ecs_instance" {
  name = "ecs-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_instance" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name = "ecs-instance-profile"
  role = aws_iam_role.ecs_instance.name
}

# IAM — ECS Task Execution Role
resource "aws_iam_role" "ecs_task_execution" {
  name = "ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ------------------------------------------------------------------
# Security Groups — ALB and ECS Instances
# ------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "ecs-alb-sg"
  description = "Security group for ECS ALB"
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
    Name = "ECS-ALB-SG"
  })
}

resource "aws_security_group" "ecs_instances" {
  name        = "ecs-instances-sg"
  description = "Security group for ECS container instances"
  vpc_id      = aws_vpc.main.id

  # Allow traffic from ALB on ephemeral ports (dynamic port mapping)
  ingress {
    description     = "Traffic from ALB"
    from_port       = 32768
    to_port         = 65535
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
    Name = "ECS-Instances-SG"
  })
}

# ------------------------------------------------------------------
# Launch Template and Auto Scaling Group
# ------------------------------------------------------------------
resource "aws_launch_template" "ecs" {
  name_prefix   = "ecs-instance-"
  image_id      = data.aws_ami.ecs_optimized.id
  instance_type = var.ecs_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ecs_instance.arn
  }

  vpc_security_group_ids = [aws_security_group.ecs_instances.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.main.name}" >> /etc/ecs/ecs.config
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "ECS Container Instance"
    })
  }

  tags = var.tags

  # Ensure IAM profile has propagated before creating the template
  depends_on = [
    aws_iam_instance_profile.ecs_instance,
    aws_ecs_cluster.main
  ]
}

resource "aws_autoscaling_group" "ecs" {
  name                = "ecs-workload-asg"
  min_size            = var.ecs_asg_min
  desired_capacity    = var.ecs_asg_desired
  max_size            = var.ecs_asg_max
  vpc_zone_identifier = [aws_subnet.workload.id, aws_subnet.workload_b.id]

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }

  # Instances need working routes to register with ECS.
  # Also ensures destroy drains instances before routes are removed.
  depends_on = [
    aws_launch_template.ecs,
    aws_route_table_association.workload,
    aws_route_table_association.workload_b
  ]
}

# ------------------------------------------------------------------
# ECS Capacity Provider
# ------------------------------------------------------------------
resource "aws_ecs_capacity_provider" "main" {
  name = "workload-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "DISABLED"

    managed_scaling {
      maximum_scaling_step_size = 2
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 100
    }
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.main.name]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = aws_ecs_capacity_provider.main.name
  }

  depends_on = [
    aws_ecs_cluster.main,
    aws_ecs_capacity_provider.main
  ]
}

# ------------------------------------------------------------------
# ALB — Application Load Balancer
# ------------------------------------------------------------------
resource "aws_lb" "ecs" {
  name               = "ecs-workload-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.alb_a.id, aws_subnet.alb_b.id]

  tags = merge(var.tags, {
    Name = "ECS Workload ALB"
  })

  # Internet-facing ALB requires an IGW attached to the VPC.
  # Also ensures ALB is destroyed before IGW on teardown.
  depends_on = [aws_internet_gateway.main]
}

resource "aws_lb_target_group" "ecs" {
  name                 = "ecs-workload-tg"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30 # Lab: 30s instead of default 300s

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
  load_balancer_arn = aws_lb.ecs.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ecs.arn
  }
}

# ------------------------------------------------------------------
# ECS Task Definition — nginx serving Hello, World!
# ------------------------------------------------------------------
resource "aws_ecs_task_definition" "hello_world" {
  family                   = "hello-world"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  cpu                      = 1024
  memory                   = 1024

  container_definitions = jsonencode([{
    name      = "hello-world"
    image     = "nginx:alpine"
    cpu       = 1024
    memory    = 1024
    essential = true

    portMappings = [{
      containerPort = 80
      hostPort      = 0 # Dynamic port mapping
      protocol      = "tcp"
    }]

    entryPoint = ["sh", "-c"]
    command = [
      "echo '<html><body><h1>Hello, World!</h1></body></html>' > /usr/share/nginx/html/index.html && nginx -g 'daemon off;'"
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/hello-world"
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
        "awslogs-create-group"  = "true"
      }
    }
  }])

  tags = var.tags
}

# ------------------------------------------------------------------
# ECS Service
# ------------------------------------------------------------------
resource "aws_ecs_service" "hello_world" {
  name            = "hello-world-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.hello_world.arn
  desired_count   = var.ecs_asg_desired

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 100
    base              = 1
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ecs.arn
    container_name   = "hello-world"
    container_port   = 80
  }

  depends_on = [
    aws_lb_listener.http,
    aws_ecs_cluster_capacity_providers.main
  ]

  tags = var.tags
}

# ------------------------------------------------------------------
# ECS Service Auto Scaling
# Scales tasks based on ALB request count.  When tasks outgrow the
# current instances, the Capacity Provider scales the ASG.
#
# With 1024 CPU per task and t3.xlarge (4096 CPU), each instance
# fits ~4 tasks.  2 instances → 8 tasks, 4 → 16, 8 → 32.
# ------------------------------------------------------------------
resource "aws_appautoscaling_target" "ecs_service" {
  max_capacity       = 32
  min_capacity       = var.ecs_asg_desired
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.hello_world.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Scale based on request count per target (aggressive for lab)
resource "aws_appautoscaling_policy" "ecs_requests" {
  name               = "ecs-request-count-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 100
    scale_in_cooldown  = 120
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.ecs.arn_suffix}/${aws_lb_target_group.ecs.arn_suffix}"
    }
  }
}

# Also scale on CPU utilisation as a safety net
resource "aws_appautoscaling_policy" "ecs_cpu" {
  name               = "ecs-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 120
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
