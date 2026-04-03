# infra/cdk/stack.py
# -------------------------------------------------------------------
# AI Client Onboarding Pipeline — AWS CDK Stack (Python)
# Provisions the same resources as the Terraform scaffold.
#
# Usage:
#   pip install aws-cdk-lib constructs
#   cdk bootstrap aws://ACCOUNT_ID/REGION
#   cdk deploy --context env=prod
# -------------------------------------------------------------------

import json
import aws_cdk as cdk
from aws_cdk import (
    Stack,
    Duration,
    RemovalPolicy,
    aws_ec2 as ec2,
    aws_rds as rds,
    aws_sqs as sqs,
    aws_s3 as s3,
    aws_ecr as ecr,
    aws_ecs as ecs,
    aws_iam as iam,
    aws_logs as logs,
    aws_secretsmanager as secretsmanager,
    aws_cloudwatch as cloudwatch,
    aws_cloudwatch_actions as cloudwatch_actions,
    aws_sns as sns,
    aws_sns_subscriptions as subscriptions,
    aws_apprunner_alpha as apprunner,
)
from constructs import Construct


class OnboardingStack(Stack):
    """
    Full AWS infrastructure for the AI Client Onboarding Pipeline.

    Instantiate with config passed via CDK context or environment variables.
    Example cdk.json context:
        {
          "app": "python infra/cdk/app.py",
          "context": {
            "notification_email": "you@yourdomain.com",
            "llm_provider": "anthropic",
            "qualify_score_threshold": "70",
            "qualify_min_budget_usd": "3000",
            "ecr_image_tag": "latest"
          }
        }
    """

    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # ── Config from context ─────────────────────────────────────
        env_name            = self.node.try_get_context("env") or "prod"
        notification_email  = self.node.try_get_context("notification_email")
        llm_provider        = self.node.try_get_context("llm_provider") or "anthropic"
        score_threshold     = self.node.try_get_context("qualify_score_threshold") or "70"
        min_budget          = self.node.try_get_context("qualify_min_budget_usd") or "3000"
        image_tag           = self.node.try_get_context("ecr_image_tag") or "latest"

        prefix = f"onboarding-{env_name}"

        # ── VPC ─────────────────────────────────────────────────────
        vpc = ec2.Vpc(
            self, "Vpc",
            vpc_name=f"{prefix}-vpc",
            max_azs=2,
            nat_gateways=1,
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="Public",
                    subnet_type=ec2.SubnetType.PUBLIC,
                    cidr_mask=24,
                ),
                ec2.SubnetConfiguration(
                    name="Private",
                    subnet_type=ec2.SubnetType.PRIVATE_WITH_EGRESS,
                    cidr_mask=24,
                ),
            ],
        )

        # ── Secrets ─────────────────────────────────────────────────
        api_key_secret = secretsmanager.Secret(
            self, "ApiKeySecret",
            secret_name=f"{prefix}/api-key",
            generate_secret_string=secretsmanager.SecretStringGenerator(
                exclude_punctuation=True,
                password_length=64,
            ),
        )

        anthropic_key_secret = secretsmanager.Secret(
            self, "AnthropicKeySecret",
            secret_name=f"{prefix}/anthropic-api-key",
            # Placeholder — update manually after deploy:
            # aws secretsmanager update-secret --secret-id onboarding-prod/anthropic-api-key --secret-string "sk-ant-..."
        )

        db_password_secret = secretsmanager.Secret(
            self, "DbPasswordSecret",
            secret_name=f"{prefix}/db-password",
            generate_secret_string=secretsmanager.SecretStringGenerator(
                exclude_punctuation=True,
                password_length=32,
            ),
        )

        # ── RDS PostgreSQL ───────────────────────────────────────────
        rds_sg = ec2.SecurityGroup(
            self, "RdsSg",
            vpc=vpc,
            description="Allow Postgres from within VPC",
            allow_all_outbound=True,
        )
        rds_sg.add_ingress_rule(
            peer=ec2.Peer.ipv4(vpc.vpc_cidr_block),
            connection=ec2.Port.tcp(5432),
            description="Postgres from VPC",
        )

        db = rds.DatabaseInstance(
            self, "Database",
            instance_identifier=f"{prefix}-db",
            engine=rds.DatabaseInstanceEngine.postgres(
                version=rds.PostgresEngineVersion.VER_16_2
            ),
            instance_type=ec2.InstanceType.of(
                ec2.InstanceClass.T4G, ec2.InstanceSize.MICRO
            ),
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(
                subnet_type=ec2.SubnetType.PRIVATE_WITH_EGRESS
            ),
            security_groups=[rds_sg],
            database_name="onboarding",
            credentials=rds.Credentials.from_secret(db_password_secret),
            backup_retention=Duration.days(7),
            deletion_protection=True,
            removal_policy=RemovalPolicy.SNAPSHOT,
            storage_encrypted=True,
        )

        # Store full DATABASE_URL in Secrets Manager
        db_url_secret = secretsmanager.Secret(
            self, "DatabaseUrlSecret",
            secret_name=f"{prefix}/database-url",
            secret_string_value=cdk.SecretValue.unsafe_plain_text(
                # Constructed at synth time — will use the RDS endpoint
                f"postgresql://onboarding@{db.db_instance_endpoint_address}:5432/onboarding"
                # Note: password is injected at runtime from db_password_secret
            ),
        )

        # ── SQS Queues ───────────────────────────────────────────────
        dlq = sqs.Queue(
            self, "DeadLetterQueue",
            queue_name=f"{prefix}-dead-letter",
            retention_period=Duration.days(14),
        )

        dead_letter_queue = sqs.DeadLetterQueue(queue=dlq, max_receive_count=3)

        classify_queue = sqs.Queue(
            self, "ClassifyQueue",
            queue_name=f"{prefix}-classify",
            visibility_timeout=Duration.seconds(180),
            retention_period=Duration.days(1),
            dead_letter_queue=dead_letter_queue,
        )

        qualify_queue = sqs.Queue(
            self, "QualifyQueue",
            queue_name=f"{prefix}-qualify",
            visibility_timeout=Duration.seconds(180),
            retention_period=Duration.days(1),
            dead_letter_queue=dead_letter_queue,
        )

        proposal_queue = sqs.Queue(
            self, "ProposalQueue",
            queue_name=f"{prefix}-generate-proposal",
            visibility_timeout=Duration.seconds(300),
            retention_period=Duration.days(1),
            dead_letter_queue=dead_letter_queue,
        )

        # ── SNS Alerts + CloudWatch Alarm ────────────────────────────
        alert_topic = sns.Topic(self, "AlertTopic", topic_name=f"{prefix}-alerts")

        if notification_email:
            alert_topic.add_subscription(
                subscriptions.EmailSubscription(notification_email)
            )

        dlq_alarm = cloudwatch.Alarm(
            self, "DlqAlarm",
            alarm_name=f"{prefix}-dlq-messages",
            metric=dlq.metric_approximate_number_of_messages_visible(
                period=Duration.minutes(5)
            ),
            threshold=0,
            evaluation_periods=1,
            comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
            alarm_description="Dead-letter queue has unprocessed messages",
        )
        dlq_alarm.add_alarm_action(cloudwatch_actions.SnsAction(alert_topic))

        # ── S3 Bucket ────────────────────────────────────────────────
        bucket = s3.Bucket(
            self, "ProposalsBucket",
            bucket_name=f"{prefix}-proposals-{self.account}",
            versioned=True,
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            encryption=s3.BucketEncryption.S3_MANAGED,
            removal_policy=RemovalPolicy.RETAIN,
            lifecycle_rules=[
                s3.LifecycleRule(
                    prefix="proposals/",
                    transitions=[
                        s3.Transition(
                            storage_class=s3.StorageClass.GLACIER,
                            transition_after=Duration.days(365),
                        )
                    ],
                )
            ],
        )

        # ── ECR Repository ───────────────────────────────────────────
        repo = ecr.Repository(
            self, "EcrRepo",
            repository_name=prefix,
            image_scan_on_push=True,
            lifecycle_rules=[
                ecr.LifecycleRule(
                    description="Keep last 10 images",
                    max_image_count=10,
                    tag_status=ecr.TagStatus.ANY,
                )
            ],
            removal_policy=RemovalPolicy.RETAIN,
        )

        # ── IAM Role (shared by API + Workers) ───────────────────────
        app_role = iam.Role(
            self, "AppRole",
            role_name=f"{prefix}-app-role",
            assumed_by=iam.CompositePrincipal(
                iam.ServicePrincipal("tasks.apprunner.amazonaws.com"),
                iam.ServicePrincipal("ecs-tasks.amazonaws.com"),
            ),
        )

        # SQS permissions
        for q in [classify_queue, qualify_queue, proposal_queue, dlq]:
            q.grant_send_messages(app_role)
            q.grant_consume_messages(app_role)

        # S3 permissions
        bucket.grant_read_write(app_role)

        # Secrets Manager permissions
        for secret in [api_key_secret, anthropic_key_secret, db_password_secret, db_url_secret]:
            secret.grant_read(app_role)

        # CloudWatch Logs
        app_role.add_to_policy(iam.PolicyStatement(
            actions=["logs:CreateLogStream", "logs:PutLogEvents"],
            resources=[f"arn:aws:logs:{self.region}:{self.account}:log-group:/ecs/{prefix}*"],
        ))

        # ── ECS Fargate (Workers) ────────────────────────────────────
        ecs_execution_role = iam.Role(
            self, "EcsExecutionRole",
            role_name=f"{prefix}-ecs-execution-role",
            assumed_by=iam.ServicePrincipal("ecs-tasks.amazonaws.com"),
            managed_policies=[
                iam.ManagedPolicy.from_aws_managed_policy_name(
                    "service-role/AmazonECSTaskExecutionRolePolicy"
                )
            ],
        )

        cluster = ecs.Cluster(
            self, "WorkerCluster",
            cluster_name=f"{prefix}-workers",
            vpc=vpc,
        )

        log_group = logs.LogGroup(
            self, "WorkerLogGroup",
            log_group_name=f"/ecs/{prefix}-worker",
            retention=logs.RetentionDays.ONE_MONTH,
            removal_policy=RemovalPolicy.DESTROY,
        )

        worker_sg = ec2.SecurityGroup(
            self, "WorkerSg",
            vpc=vpc,
            description="ECS worker outbound access",
            allow_all_outbound=True,
        )

        shared_env = {
            "APP_MODE":                 "worker",
            "AWS_REGION":               self.region,
            "SECRETS_PREFIX":           f"{prefix}/",
            "LLM_PROVIDER":             llm_provider,
            "QUALIFY_SCORE_THRESHOLD":  score_threshold,
            "QUALIFY_MIN_BUDGET_USD":   min_budget,
            "SQS_CLASSIFY_URL":         classify_queue.queue_url,
            "SQS_QUALIFY_URL":          qualify_queue.queue_url,
            "SQS_PROPOSAL_URL":         proposal_queue.queue_url,
            "S3_BUCKET":                bucket.bucket_name,
            "NOTIFICATION_EMAIL":       notification_email or "",
        }

        task_def = ecs.FargateTaskDefinition(
            self, "WorkerTaskDef",
            family=f"{prefix}-worker",
            cpu=256,
            memory_limit_mib=512,
            task_role=app_role,
            execution_role=ecs_execution_role,
        )

        task_def.add_container(
            "worker",
            image=ecs.ContainerImage.from_ecr_repository(repo, tag=image_tag),
            command=["python", "-m", "app.workers.runner"],
            environment=shared_env,
            logging=ecs.LogDrivers.aws_logs(
                stream_prefix="worker",
                log_group=log_group,
            ),
        )

        ecs.FargateService(
            self, "WorkerService",
            cluster=cluster,
            task_definition=task_def,
            service_name=f"{prefix}-worker",
            desired_count=1,
            security_groups=[worker_sg],
            vpc_subnets=ec2.SubnetSelection(
                subnet_type=ec2.SubnetType.PRIVATE_WITH_EGRESS
            ),
        )

        # ── App Runner (API) ─────────────────────────────────────────
        api_env = {**shared_env, "APP_MODE": "api"}

        api_service = apprunner.Service(
            self, "ApiService",
            service_name=f"{prefix}-api",
            source=apprunner.Source.from_ecr(
                image_configuration=apprunner.ImageConfiguration(
                    port=8000,
                    environment_variables=api_env,
                ),
                repository=repo,
                tag=image_tag,
            ),
            instance_role=app_role,
            cpu=apprunner.Cpu.QUARTER_VCPU,
            memory=apprunner.Memory.HALF_GB,
        )

        # ── Outputs ──────────────────────────────────────────────────
        cdk.CfnOutput(self, "ApiUrl",
            value=f"https://{api_service.service_url}",
            description="App Runner API URL",
        )
        cdk.CfnOutput(self, "EcrRepoUrl",
            value=repo.repository_uri,
            description="ECR repository URI for Docker push",
        )
        cdk.CfnOutput(self, "S3BucketName",
            value=bucket.bucket_name,
            description="S3 bucket for proposals",
        )
        cdk.CfnOutput(self, "ClassifyQueueUrl",
            value=classify_queue.queue_url,
            description="SQS classify queue URL",
        )
        cdk.CfnOutput(self, "DlqUrl",
            value=dlq.queue_url,
            description="Dead-letter queue URL — monitor this",
        )
