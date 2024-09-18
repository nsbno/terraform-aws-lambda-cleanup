terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.0.0"
    }
  }
}

locals {
  port             = 80
  protocol         = "tcp"
  application_name = "lambda-cleanup"
  container_name   = "image-cleanup"
  launch_type      = "FARGATE"
}


data "aws_region" "current" {}

data "aws_vpc" "main" {
  tags = {
    Name = "shared"
  }
}

data "aws_subnets" "private" {
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.main.id]
  }

  tags = {
    Tier = "Private"
  }
}

resource "aws_ecs_task_definition" "task" {
  family = local.application_name
  container_definitions = jsonencode([
    {
      name  = local.container_name
      image = "ghcr.io/karl-cardenas-coding/go-lambda-cleanup:v2.0.14"
      portMappings = [
        {
          containerPort = tonumber(local.port)
          hostPort = tonumber(local.port)
          protocol = local.protocol
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group" : aws_cloudwatch_log_group.main.name,
          "awslogs-region" : data.aws_region.current.name,
          "awslogs-stream-prefix" : local.container_name
        }
      }
      environment = []
    }
  ])

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  requires_compatibilities = [local.launch_type]
  cpu          = 256
  memory       = 512
  network_mode = "awsvpc"
}

resource "aws_cloudwatch_log_group" "main" {
  name              = local.application_name
  retention_in_days = 30
}


/*
 * == Task Role
 *
 * Gives the actual containers the permissions they need
 */
resource "aws_iam_role" "task" {
  name               = "${local.application_name}-task-role"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
}

resource "aws_iam_role_policy" "ecs_task_permissions" {
  name   = "${local.application_name}-permissions"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.ecs_task_logs.json
}

data "aws_iam_policy_document" "ecs_task_logs" {
  statement {
    effect = "Allow"

    resources = [
      aws_cloudwatch_log_group.main.arn,
    ]

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
  }
  statement {
    effect = "Allow"

    resources = [
      "*",
    ]

    actions = [
      "lambda:ListFunctions",
      "lambda:ListVersionsByFunction",
      "lambda:ListAliases",
      "lambda:DeleteFunction"
    ]
  }
}

/*
 * = IAM
 *
 * Various permissions needed for the module to function
 */

data "aws_iam_policy_document" "task_assume" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

/*
 * == Task execution role
 *
 * This allows the task to pull from ECR, etc
 */
resource "aws_iam_role" "execution" {
  name               = "${local.application_name}-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
}

resource "aws_iam_role_policy" "task_execution" {
  name   = "${local.application_name}-task-execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.task_execution_permissions.json
}

data "aws_iam_policy_document" "task_execution_permissions" {
  statement {
    effect = "Allow"

    resources = [
      "*",
    ]

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
  }
}

# SCHEDULER
resource "aws_ecs_cluster" "ecs_cluster" {
  name = "${local.application_name}-cluster"
}


resource "aws_security_group" "allow_egress" {
  name        = "allow_egress"
  description = "Allow all outbound traffic"
  vpc_id      = data.aws_vpc.main.id

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "allow_egress"
  }
}
resource "aws_scheduler_schedule" "weekly_schedule" {
  name        = "ecs_task_weekly_schedule"
  description = "Scheduled rule to run the ECS task every week"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "cron(0 0 ? * 1 *)" # Adjust the cron expression as needed

  target {
    arn      = aws_ecs_cluster.ecs_cluster.arn
    role_arn = aws_iam_role.scheduler_role.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.task.arn
      launch_type         = "FARGATE"

      network_configuration {
        assign_public_ip = false
        security_groups = [aws_security_group.allow_egress.id]
        subnets          = data.aws_subnets.private.ids
      }
    }
    input = jsonencode({
      containerOverrides = [
        {
          name = local.container_name
          command = ["glc","clean","-r","eu-west-1","-c","3"]
        }
      ]
    })

  }
}

resource "aws_iam_role" "scheduler_role" {
  name = "scheduler_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "scheduler_policy" {
  name = "scheduler_policy"
  role = aws_iam_role.scheduler_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "ecs:RunTask",
          "iam:PassRole"
        ],
        Effect   = "Allow",
        Resource = "*"
      }
    ]
  })
}
