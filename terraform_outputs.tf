# infra/terraform/outputs.tf
# -------------------------------------------------------------------
# Outputs from the AI Client Onboarding Pipeline infrastructure.
# Use these to wire up your application config and CI/CD pipelines.
# -------------------------------------------------------------------

output "api_url" {
  description = "App Runner service URL for the intake API."
  value       = "https://${aws_apprunner_service.api.service_url}"
}

output "ecr_repository_url" {
  description = "ECR repository URL. Use this when tagging and pushing Docker images."
  value       = aws_ecr_repository.app.repository_url
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (host:port). Used in DATABASE_URL."
  value       = aws_db_instance.main.endpoint
}

output "s3_bucket_name" {
  description = "S3 bucket name for proposal documents and templates."
  value       = aws_s3_bucket.proposals.bucket
}

output "sqs_classify_url" {
  description = "SQS queue URL for the classify job queue."
  value       = aws_sqs_queue.classify.url
}

output "sqs_qualify_url" {
  description = "SQS queue URL for the qualify job queue."
  value       = aws_sqs_queue.qualify.url
}

output "sqs_generate_proposal_url" {
  description = "SQS queue URL for the generate_proposal job queue."
  value       = aws_sqs_queue.generate_proposal.url
}

output "sqs_dead_letter_url" {
  description = "SQS dead-letter queue URL. Monitor this for failed jobs."
  value       = aws_sqs_queue.dead_letter.url
}

output "ecs_cluster_name" {
  description = "ECS cluster name for the worker service."
  value       = aws_ecs_cluster.workers.name
}

output "ecs_worker_service_name" {
  description = "ECS service name. Use to force redeployments and check status."
  value       = aws_ecs_service.worker.name
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for worker logs."
  value       = aws_cloudwatch_log_group.worker.name
}

output "secrets_prefix" {
  description = "Secrets Manager prefix. All app secrets are stored under this path."
  value       = "${local.prefix}/"
}

output "database_url_secret_arn" {
  description = "ARN of the Secrets Manager secret containing DATABASE_URL."
  value       = aws_secretsmanager_secret.database_url.arn
  sensitive   = true
}

output "app_iam_role_arn" {
  description = "IAM role ARN granted to both API and worker tasks."
  value       = aws_iam_role.app.arn
}

# ── CI/CD helper snippet ────────────────────────────────────────────
# Copy this into your GitHub Actions workflow to deploy a new image:
#
# - name: Deploy to ECR + App Runner
#   run: |
#     ECR_URL=$(terraform output -raw ecr_repository_url)
#     aws ecr get-login-password | docker login --username AWS --password-stdin $ECR_URL
#     docker build -t $ECR_URL:$GITHUB_SHA .
#     docker push $ECR_URL:$GITHUB_SHA
#     # App Runner auto-deploys on new image push (auto_deployments_enabled = true)
#     # Force ECS worker to pick up the new image:
#     CLUSTER=$(terraform output -raw ecs_cluster_name)
#     SERVICE=$(terraform output -raw ecs_worker_service_name)
#     aws ecs update-service --cluster $CLUSTER --service $SERVICE --force-new-deployment
