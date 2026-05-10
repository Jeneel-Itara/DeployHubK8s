# ── ECS Cluster ───────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "monitoring" {
  name = "${var.project}-monitoring"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "monitoring" {
  cluster_name       = aws_ecs_cluster.monitoring.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ── CloudWatch Log Group ──────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "monitoring" {
  name = "/ecs/${var.project}-monitoring"
  # retention_in_days omitted — KodeKloud IAM restricts logs:PutRetentionPolicy
  tags = var.tags
}

# ── IAM — ECS Task Execution Role ────────────────────────────────────────────
resource "aws_iam_role" "ecs_execution" {
  name = "${var.project}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow execution role to read Secrets Manager — using managed attachment
# (inline PutRolePolicy is restricted on KodeKloud)
resource "aws_iam_role_policy_attachment" "ecs_secrets" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

# ── IAM — ECS Task Role ───────────────────────────────────────────────────────
resource "aws_iam_role" "ecs_task" {
  name = "${var.project}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

# ── Secrets Manager — Grafana credentials ────────────────────────────────────
resource "aws_secretsmanager_secret" "grafana" {
  name                    = "${var.project}/grafana-credentials"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id = aws_secretsmanager_secret.grafana.id
  secret_string = jsonencode({
    "admin-user"     = var.grafana_admin_user
    "admin-password" = var.grafana_admin_password
  })
}

# ── Prometheus Task Definition ────────────────────────────────────────────────
# Uses ephemeral storage (no EFS needed for demo sessions)
resource "aws_ecs_task_definition" "prometheus" {
  family                   = "${var.project}-prometheus"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  ephemeral_storage {
    size_in_gib = 21  # minimum is 21, enough for demo metrics
  }

  container_definitions = jsonencode([{
    name      = "prometheus"
    image     = "prom/prometheus:v2.52.0"
    essential = true

    command = [
      "--config.file=/etc/prometheus/prometheus.yml",
      "--storage.tsdb.path=/prometheus",
      "--storage.tsdb.retention.time=3h",
      "--web.enable-lifecycle"
    ]

    portMappings = [{ containerPort = 9090, protocol = "tcp" }]

    environment = [{
      name  = "EKS_METRICS_ENDPOINT"
      value = var.eks_metrics_endpoint
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.monitoring.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "prometheus"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://localhost:9090/-/healthy || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 15
    }
  }])

  tags = var.tags
}

# ── Grafana Task Definition ───────────────────────────────────────────────────
resource "aws_ecs_task_definition" "grafana" {
  family                   = "${var.project}-grafana"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "grafana"
    image     = "grafana/grafana:11.0.0"
    essential = true

    portMappings = [{ containerPort = 3000, protocol = "tcp" }]

    environment = [
      { name = "GF_USERS_ALLOW_SIGN_UP",           value = "false" },
      { name = "GF_SERVER_ROOT_URL",                value = "http://${var.alb_dns_name}/grafana" },
      { name = "GF_SERVER_SERVE_FROM_SUB_PATH",     value = "true" }
    ]

    secrets = [
      { name = "GF_SECURITY_ADMIN_USER",     valueFrom = "${aws_secretsmanager_secret.grafana.arn}:admin-user::" },
      { name = "GF_SECURITY_ADMIN_PASSWORD", valueFrom = "${aws_secretsmanager_secret.grafana.arn}:admin-password::" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.monitoring.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "grafana"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://localhost:3000/api/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
  }])

  tags = var.tags
}

# ── Loki Task Definition ──────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "loki" {
  family                   = "${var.project}-loki"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "loki"
    image     = "grafana/loki:3.0.0"
    essential = true

    command = ["-config.file=/etc/loki/loki.yaml"]

    portMappings = [
      { containerPort = 3100, protocol = "tcp" },
      { containerPort = 9096, protocol = "tcp" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.monitoring.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "loki"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://localhost:3100/ready || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 15
    }
  }])

  tags = var.tags
}

# ── ECS Services ──────────────────────────────────────────────────────────────
resource "aws_ecs_service" "prometheus" {
  name            = "${var.project}-prometheus"
  cluster         = aws_ecs_cluster.monitoring.id
  task_definition = aws_ecs_task_definition.prometheus.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_tasks_security_group_id]
    assign_public_ip = false
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200

  tags = var.tags
}

resource "aws_ecs_service" "grafana" {
  name            = "${var.project}-grafana"
  cluster         = aws_ecs_cluster.monitoring.id
  task_definition = aws_ecs_task_definition.grafana.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_tasks_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.grafana_target_group_arn
    container_name   = "grafana"
    container_port   = 3000
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200

  tags = var.tags
}

resource "aws_ecs_service" "loki" {
  name            = "${var.project}-loki"
  cluster         = aws_ecs_cluster.monitoring.id
  task_definition = aws_ecs_task_definition.loki.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_tasks_security_group_id]
    assign_public_ip = false
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200

  tags = var.tags
}
