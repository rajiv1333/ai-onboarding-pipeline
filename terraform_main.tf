# infra/terraform/main.tf
# -------------------------------------------------------------------
# AI Client Onboarding Pipeline — AWS Infrastructure
# Provisions: VPC, RDS, SQS, S3, ECR, App Runner, ECS Fargate, IAM
# -------------------------------------------------------------------

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment to store state in S3 (recommended for production)
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "onboarding/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  prefix = "${var.project}-${var.environment}"
}

# ── Data sources ────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }

# ── VPC ─────────────────────────────────────────────────────────────

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.prefix}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true   # cost optimisation — 1 NAT for small scale
  enable_dns_hostnames = true
  enable_dns_support   = true
}

# ── Secrets Manager ─────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "api_key" {
  name                    = "${local.prefix}/api-key"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "api_key" {
  secret_id     = aws_secretsmanager_secret.api_key.id
  secret_string = var.api_key
}

resource "aws_secretsmanager_secret" "anthropic_key" {
  name                    = "${local.prefix}/anthropic-api-key"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "anthropic_key" {
  secret_id     = aws_secretsmanager_secret.anthropic_key.id
  secret_string = var.anthropic_api_key
}

resource "aws_secretsmanager_secret" "sendgrid_key" {
  count                   = var.sendgrid_api_key != "" ? 1 : 0
  name                    = "${local.prefix}/sendgrid-api-key"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "sendgrid_key" {
  count         = var.sendgrid_api_key != "" ? 1 : 0
  secret_id     = aws_secretsmanager_secret.sendgrid_key[0].id
  secret_string = var.sendgrid_api_key
}

# ── RDS PostgreSQL ──────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name       = "${local.prefix}-db-subnets"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "rds" {
  name        = "${local.prefix}-rds-sg"
  description = "Allow Postgres from within VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "main" {
  identifier        = "${local.prefix}-db"
  engine            = "postgres"
  engine_version    = "16.2"
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  backup_retention_period = var.db_backup_retention_days
  skip_final_snapshot     = false
  final_snapshot_identifier = "${local.prefix}-db-final-snapshot"

  # Store the connection URL in Secrets Manager after creation
  # (done via null_resource or post-apply script — see outputs.tf)
}

resource "aws_secretsmanager_secret" "database_url" {
  name                    = "${local.prefix}/database-url"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "database_url" {
  secret_id = aws_secretsmanager_secret.database_url.id
  secret_string = "postgresql://${var.db_username}:${var.db_password}@${aws_db_instance.main.endpoint}/${var.db_name}"
}

# ── SQS Queues ──────────────────────────────────────────────────────

resource "aws_sqs_queue" "dead_letter" {
  name                      = "${local.prefix}-dead-letter"
  message_retention_seconds = 1209600  # 14 days
}

resource "aws_sqs_queue" "classify" {
  name                       = "${local.prefix}-classify"
  visibility_timeout_seconds = 180
  message_retention_seconds  = 86400

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "qualify" {
  name                       = "${local.prefix}-qualify"
  visibility_timeout_seconds = 180
  message_retention_seconds  = 86400

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "generate_proposal" {
  name                       = "${local.prefix}-generate-proposal"
  visibility_timeout_seconds = 300   # proposal generation can take up to ~2 min
  message_retention_seconds  = 86400

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter.arn
    maxReceiveCount     = 3
  })
}

# CloudWatch alarm for DLQ depth
resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "${local.prefix}-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Dead-letter queue has unprocessed messages"

  dimensions = {
    QueueName = aws_sqs_queue.dead_letter.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_sns_topic" "alerts" {
  name = "${local.prefix}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ── S3 Bucket ───────────────────────────────────────────────────────

resource "aws_s3_bucket" "proposals" {
  bucket = "${local.prefix}-proposals-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "proposals" {
  bucket = aws_s3_bucket.proposals.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "proposals" {
  bucket                  = aws_s3_bucket.proposals.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "proposals" {
  bucket = aws_s3_bucket.proposals.id

  rule {
    id     = "archive-old-proposals"
    status = "Enabled"
    filter { prefix = "proposals/" }
    transition {
      days          = 365
      storage_class = "GLACIER"
    }
  }
}

# ── ECR Repository ──────────────────────────────────────────────────

resource "aws_ecr_repository" "app" {
  name                 = local.prefix
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ── IAM ─────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "app_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["tasks.apprunner.amazonaws.com", "ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${local.prefix}-app-role"
  assume_role_policy = data.aws_iam_policy_document.app_trust.json
}

data "aws_iam_policy_document" "app_permissions" {
  # SQS — all four queues
  statement {
    actions   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [
      aws_sqs_queue.classify.arn,
      aws_sqs_queue.qualify.arn,
      aws_sqs_queue.generate_proposal.arn,
      aws_sqs_queue.dead_letter.arn,
    ]
  }

  # S3 — proposals bucket only
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.proposals.arn,
      "${aws_s3_bucket.proposals.arn}/*",
    ]
  }

  # Secrets Manager — read all onboarding secrets
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${local.prefix}/*"]
  }

  # CloudWatch Logs
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${local.prefix}*"]
  }
}

resource "aws_iam_policy" "app" {
  name   = "${local.prefix}-app-policy"
  policy = data.aws_iam_policy_document.app_permissions.json
}

resource "aws_iam_role_policy_attachment" "app" {
  role       = aws_iam_role.app.name
  policy_arn = aws_iam_policy.app.arn
}

# ECS execution role (separate — used by Fargate control plane to pull image + write logs)
data "aws_iam_policy_document" "ecs_execution_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${local.prefix}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_execution_trust.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── App Runner (API) ────────────────────────────────────────────────

resource "aws_apprunner_service" "api" {
  service_name = "${local.prefix}-api"

  source_configuration {
    image_repository {
      image_identifier      = "${aws_ecr_repository.app.repository_url}:${var.ecr_image_tag}"
      image_repository_type = "ECR"

      image_configuration {
        port = "8000"
        runtime_environment_variables = {
          APP_MODE        = "api"
          AWS_REGION      = var.aws_region
          SECRETS_PREFIX  = "${local.prefix}/"
          LLM_PROVIDER    = var.llm_provider
          QUALIFY_SCORE_THRESHOLD = tostring(var.qualify_score_threshold)
          QUALIFY_MIN_BUDGET_USD  = tostring(var.qualify_min_budget_usd)
          SQS_CLASSIFY_URL        = aws_sqs_queue.classify.url
          SQS_QUALIFY_URL         = aws_sqs_queue.qualify.url
          SQS_PROPOSAL_URL        = aws_sqs_queue.generate_proposal.url
          S3_BUCKET               = aws_s3_bucket.proposals.bucket
        }
      }
    }

    auto_deployments_enabled = true
  }

  instance_configuration {
    cpu               = var.api_cpu
    memory            = var.api_memory
    instance_role_arn = aws_iam_role.app.arn
  }

  depends_on = [aws_ecr_repository.app]
}

# ── ECS Fargate (Workers) ───────────────────────────────────────────

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${local.prefix}-worker"
  retention_in_days = 30
}

resource "aws_ecs_cluster" "workers" {
  name = "${local.prefix}-workers"
}

resource "aws_security_group" "worker" {
  name        = "${local.prefix}-worker-sg"
  description = "ECS worker outbound access"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.prefix}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_cpu
  memory                   = var.worker_memory
  task_role_arn            = aws_iam_role.app.arn
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([{
    name      = "worker"
    image     = "${aws_ecr_repository.app.repository_url}:${var.ecr_image_tag}"
    essential = true

    command = ["python", "-m", "app.workers.runner"]

    environment = [
      { name = "APP_MODE",               value = "worker" },
      { name = "AWS_REGION",             value = var.aws_region },
      { name = "SECRETS_PREFIX",         value = "${local.prefix}/" },
      { name = "LLM_PROVIDER",           value = var.llm_provider },
      { name = "QUALIFY_SCORE_THRESHOLD",value = tostring(var.qualify_score_threshold) },
      { name = "QUALIFY_MIN_BUDGET_USD", value = tostring(var.qualify_min_budget_usd) },
      { name = "SQS_CLASSIFY_URL",       value = aws_sqs_queue.classify.url },
      { name = "SQS_QUALIFY_URL",        value = aws_sqs_queue.qualify.url },
      { name = "SQS_PROPOSAL_URL",       value = aws_sqs_queue.generate_proposal.url },
      { name = "S3_BUCKET",              value = aws_s3_bucket.proposals.bucket },
      { name = "NOTIFICATION_EMAIL",     value = var.notification_email },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.worker.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "worker"
      }
    }
  }])
}

resource "aws_ecs_service" "worker" {
  name            = "${local.prefix}-worker"
  cluster         = aws_ecs_cluster.workers.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = false
  }

  # Ignore desired_count changes made outside Terraform (e.g. manual scaling)
  lifecycle {
    ignore_changes = [desired_count]
  }
}
