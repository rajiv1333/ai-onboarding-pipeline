# infra/terraform/variables.tf
# -------------------------------------------------------------------
# Input variables for the AI Client Onboarding Pipeline on AWS.
# Supply values via terraform.tfvars or environment variables
# (TF_VAR_<name>). Never commit secrets to version control.
# -------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy all resources into."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short project name used as a prefix for all resource names."
  type        = string
  default     = "onboarding"
}

variable "environment" {
  description = "Deployment environment label (e.g. prod, staging)."
  type        = string
  default     = "prod"
}

# ── Database ────────────────────────────────────────────────────────

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_name" {
  description = "Name of the PostgreSQL database."
  type        = string
  default     = "onboarding"
}

variable "db_username" {
  description = "Master username for RDS."
  type        = string
  default     = "onboarding"
}

variable "db_password" {
  description = "Master password for RDS. Mark sensitive — supply via TF_VAR_db_password."
  type        = string
  sensitive   = true
}

variable "db_backup_retention_days" {
  description = "Number of days to retain automated RDS backups."
  type        = number
  default     = 7
}

# ── Application secrets ─────────────────────────────────────────────

variable "api_key" {
  description = "API key for the intake gateway. Generate with: openssl rand -hex 32"
  type        = string
  sensitive   = true
}

variable "anthropic_api_key" {
  description = "Anthropic Claude API key."
  type        = string
  sensitive   = true
  default     = ""
}

variable "openai_api_key" {
  description = "OpenAI API key (used if llm_provider = openai)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "llm_provider" {
  description = "LLM provider to use: 'anthropic' or 'openai'."
  type        = string
  default     = "anthropic"

  validation {
    condition     = contains(["anthropic", "openai"], var.llm_provider)
    error_message = "llm_provider must be 'anthropic' or 'openai'."
  }
}

variable "sendgrid_api_key" {
  description = "SendGrid API key for email notifications. Leave empty to use SES instead."
  type        = string
  sensitive   = true
  default     = ""
}

variable "notification_email" {
  description = "Email address to notify when a lead is ready for review."
  type        = string
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL. Leave empty to skip Slack notifications."
  type        = string
  sensitive   = true
  default     = ""
}

# ── Qualification thresholds ────────────────────────────────────────

variable "qualify_score_threshold" {
  description = "Minimum LLM fit score (0–100) to auto-advance a lead to proposal generation."
  type        = number
  default     = 70
}

variable "qualify_min_budget_usd" {
  description = "Minimum budget in USD to auto-qualify without LLM scoring."
  type        = number
  default     = 3000
}

# ── Container image ─────────────────────────────────────────────────

variable "ecr_image_tag" {
  description = "Docker image tag to deploy. Defaults to 'latest'; use a specific SHA in CI."
  type        = string
  default     = "latest"
}

# ── Compute sizing ──────────────────────────────────────────────────

variable "api_cpu" {
  description = "App Runner CPU allocation (0.25 vCPU, 0.5 vCPU, 1 vCPU, 2 vCPU, 4 vCPU)."
  type        = string
  default     = "0.25 vCPU"
}

variable "api_memory" {
  description = "App Runner memory allocation (0.5 GB, 1 GB, 2 GB, 3 GB, 4 GB)."
  type        = string
  default     = "0.5 GB"
}

variable "worker_cpu" {
  description = "ECS Fargate task CPU units (256 = 0.25 vCPU, 512, 1024, 2048)."
  type        = number
  default     = 256
}

variable "worker_memory" {
  description = "ECS Fargate task memory in MiB."
  type        = number
  default     = 512
}

variable "worker_desired_count" {
  description = "Number of ECS worker tasks to run."
  type        = number
  default     = 1
}
