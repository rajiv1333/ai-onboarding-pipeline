# AWS Infrastructure Runbook

Step-by-step procedures for deploying the AI Client Onboarding Pipeline on AWS. Assumes you have an AWS account and the AWS CLI configured (`aws configure`).

> **If you prefer infrastructure-as-code**, skip to the Terraform or CDK scaffolds — they provision everything in sections 2–7 automatically. Use this runbook for understanding, manual troubleshooting, or one-off tasks.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [IAM Roles & Policies](#2-iam-roles--policies)
3. [Secrets Manager](#3-secrets-manager)
4. [RDS PostgreSQL](#4-rds-postgresql)
5. [Amazon SQS Queues](#5-amazon-sqs-queues)
6. [Amazon S3 Bucket](#6-amazon-s3-bucket)
7. [Amazon SES (Email)](#7-amazon-ses-email)
8. [Deploy API — AWS App Runner](#8-deploy-api--aws-app-runner)
9. [Deploy Workers — ECS Fargate](#9-deploy-workers--ecs-fargate)
10. [Deploy Dashboard — AWS Amplify](#10-deploy-dashboard--aws-amplify)
11. [CloudWatch Alarms](#11-cloudwatch-alarms)
12. [Rotating Secrets](#12-rotating-secrets)
13. [Handling a Dead-Letter Queue](#13-handling-a-dead-letter-queue)
14. [Scaling Workers](#14-scaling-workers)
15. [Incident Response Checklist](#15-incident-response-checklist)

---

## 1. Prerequisites

```bash
# Verify CLI is configured
aws sts get-caller-identity

# Set your preferred region (e.g. us-east-1, eu-west-1)
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Install additional tools
pip install awscli --upgrade
npm install -g aws-cdk        # if using CDK
```

Choose a region and use it consistently throughout. All resources must be in the same region.

---

## 2. IAM Roles & Policies

### App Runner task role (API)

```bash
# Create trust policy
cat > /tmp/apprunner-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "tasks.apprunner.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name onboarding-api-role \
  --assume-role-policy-document file:///tmp/apprunner-trust.json

# Attach permissions: SQS send, S3 read/write, Secrets Manager read
aws iam attach-role-policy \
  --role-name onboarding-api-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSQSFullAccess

aws iam attach-role-policy \
  --role-name onboarding-api-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

aws iam attach-role-policy \
  --role-name onboarding-api-role \
  --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite
```

### ECS task role (Workers)

```bash
cat > /tmp/ecs-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ecs-tasks.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name onboarding-worker-role \
  --assume-role-policy-document file:///tmp/ecs-trust.json

aws iam attach-role-policy \
  --role-name onboarding-worker-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSQSFullAccess

aws iam attach-role-policy \
  --role-name onboarding-worker-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

aws iam attach-role-policy \
  --role-name onboarding-worker-role \
  --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite

# ECS execution role (needed for Fargate to pull ECR images + write logs)
aws iam create-role \
  --role-name onboarding-ecs-execution-role \
  --assume-role-policy-document file:///tmp/ecs-trust.json

aws iam attach-role-policy \
  --role-name onboarding-ecs-execution-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```

> **Security note:** For production, replace the broad managed policies with least-privilege inline policies scoped to your specific bucket and queue ARNs. The Terraform/CDK scaffolds do this automatically.

---

## 3. Secrets Manager

Store all sensitive config here. The app reads secrets at startup via `boto3`.

```bash
# Generate a strong API key
API_KEY=$(openssl rand -hex 32)

# Store each secret
aws secretsmanager create-secret \
  --name "onboarding/api-key" \
  --secret-string "$API_KEY" \
  --region $AWS_REGION

aws secretsmanager create-secret \
  --name "onboarding/anthropic-api-key" \
  --secret-string "sk-ant-YOUR-KEY-HERE" \
  --region $AWS_REGION

aws secretsmanager create-secret \
  --name "onboarding/database-url" \
  --secret-string "postgresql://onboarding:PASSWORD@YOUR-RDS-ENDPOINT:5432/onboarding" \
  --region $AWS_REGION

aws secretsmanager create-secret \
  --name "onboarding/sendgrid-api-key" \
  --secret-string "SG.YOUR-KEY-HERE" \
  --region $AWS_REGION
```

**Retrieve a secret value (for verification):**

```bash
aws secretsmanager get-secret-value \
  --secret-id "onboarding/api-key" \
  --query SecretString \
  --output text
```

---

## 4. RDS PostgreSQL

### Create a subnet group and security group

```bash
# Get your default VPC
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)

# Get subnet IDs (need at least 2 AZs for RDS)
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[*].SubnetId" --output text | tr '\t' ',')

# Create DB subnet group
aws rds create-db-subnet-group \
  --db-subnet-group-name onboarding-db-subnets \
  --db-subnet-group-description "Onboarding pipeline DB subnets" \
  --subnet-ids $(echo $SUBNET_IDS | tr ',' ' ')

# Create security group for RDS
SG_ID=$(aws ec2 create-security-group \
  --group-name onboarding-rds-sg \
  --description "RDS access for onboarding pipeline" \
  --vpc-id $VPC_ID \
  --query GroupId --output text)

# Allow inbound Postgres from within the VPC
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID \
  --query "Vpcs[0].CidrBlock" --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 5432 \
  --cidr $VPC_CIDR
```

### Create the database instance

```bash
aws rds create-db-instance \
  --db-instance-identifier onboarding-db \
  --db-instance-class db.t4g.micro \
  --engine postgres \
  --engine-version 16.2 \
  --master-username onboarding \
  --master-user-password "YOUR-STRONG-PASSWORD" \
  --allocated-storage 20 \
  --db-name onboarding \
  --vpc-security-group-ids $SG_ID \
  --db-subnet-group-name onboarding-db-subnets \
  --backup-retention-period 7 \
  --no-publicly-accessible \
  --tags Key=Project,Value=ai-onboarding
```

Wait for the instance to be available (~5 minutes):

```bash
aws rds wait db-instance-available \
  --db-instance-identifier onboarding-db

# Get the endpoint
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier onboarding-db \
  --query "DBInstances[0].Endpoint.Address" \
  --output text)

echo "RDS endpoint: $RDS_ENDPOINT"
```

Update the `onboarding/database-url` secret with the real endpoint:

```bash
aws secretsmanager update-secret \
  --secret-id "onboarding/database-url" \
  --secret-string "postgresql://onboarding:YOUR-PASSWORD@${RDS_ENDPOINT}:5432/onboarding"
```

### Run migrations

From your local machine with the RDS security group allowing your IP temporarily:

```bash
DATABASE_URL="postgresql://onboarding:PASSWORD@${RDS_ENDPOINT}:5432/onboarding" \
  alembic upgrade head
```

---

## 5. Amazon SQS Queues

Create three processing queues and one dead-letter queue.

```bash
# Dead-letter queue first
DLQ_URL=$(aws sqs create-queue \
  --queue-name onboarding-dead-letter \
  --attributes MessageRetentionPeriod=1209600 \
  --query QueueUrl --output text)

DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url $DLQ_URL \
  --attribute-names QueueArn \
  --query Attributes.QueueArn --output text)

# Redrive policy (move to DLQ after 3 failures)
REDRIVE_POLICY="{\"deadLetterTargetArn\":\"${DLQ_ARN}\",\"maxReceiveCount\":\"3\"}"

# Create the three processing queues
for QUEUE in classify qualify generate-proposal; do
  aws sqs create-queue \
    --queue-name "onboarding-${QUEUE}" \
    --attributes \
      VisibilityTimeout=180 \
      MessageRetentionPeriod=86400 \
      "RedrivePolicy=${REDRIVE_POLICY}" \
    --tags Project=ai-onboarding
  echo "Created: onboarding-${QUEUE}"
done
```

**Note:** `VisibilityTimeout=180` (3 minutes) gives each worker enough time to complete. Increase to `300` if proposal generation is slow.

---

## 6. Amazon S3 Bucket

```bash
BUCKET_NAME="ai-onboarding-proposals-${AWS_ACCOUNT_ID}"

aws s3api create-bucket \
  --bucket $BUCKET_NAME \
  --region $AWS_REGION \
  --create-bucket-configuration LocationConstraint=$AWS_REGION

# Block all public access
aws s3api put-public-access-block \
  --bucket $BUCKET_NAME \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,\
BlockPublicPolicy=true,RestrictPublicBuckets=true

# Enable versioning (protects proposal docs)
aws s3api put-bucket-versioning \
  --bucket $BUCKET_NAME \
  --versioning-configuration Status=Enabled

# Lifecycle: move objects to Glacier after 1 year
aws s3api put-bucket-lifecycle-configuration \
  --bucket $BUCKET_NAME \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "archive-old-proposals",
      "Status": "Enabled",
      "Filter": { "Prefix": "proposals/" },
      "Transitions": [{ "Days": 365, "StorageClass": "GLACIER" }]
    }]
  }'

echo "Bucket: $BUCKET_NAME"
```

Upload the proposal base template:

```bash
aws s3 cp app/templates/proposal_base.docx \
  s3://${BUCKET_NAME}/templates/proposal_base.docx
```

---

## 7. Amazon SES (Email)

### Verify your sending domain

```bash
# Verify your domain (replace with your actual domain)
aws ses verify-domain-identity \
  --domain yourdomain.com \
  --region $AWS_REGION
```

AWS returns a TXT record to add to your DNS. Add it, then verify:

```bash
aws ses get-identity-verification-attributes \
  --identities yourdomain.com \
  --query "VerificationAttributes.\"yourdomain.com\".VerificationStatus" \
  --output text
# Should return: Success
```

### Request production access

By default SES is in sandbox mode (can only send to verified addresses). Submit a production access request:

```bash
aws ses put-account-sending-attributes \
  --sending-enabled   # only works after production access is granted
```

Go to AWS Console → SES → Account Dashboard → Request Production Access and fill in the form. Takes 24–48 hours.

---

## 8. Deploy API — AWS App Runner

### Push your Docker image to ECR

```bash
# Create ECR repository
aws ecr create-repository \
  --repository-name ai-onboarding \
  --region $AWS_REGION

ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/ai-onboarding"

# Login and push
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $ECR_URI

docker build -t ai-onboarding .
docker tag ai-onboarding:latest ${ECR_URI}:latest
docker push ${ECR_URI}:latest
```

### Create the App Runner service

```bash
cat > /tmp/apprunner-config.json << EOF
{
  "ServiceName": "ai-onboarding-api",
  "SourceConfiguration": {
    "ImageRepository": {
      "ImageIdentifier": "${ECR_URI}:latest",
      "ImageRepositoryType": "ECR",
      "ImageConfiguration": {
        "Port": "8000",
        "RuntimeEnvironmentVariables": {
          "APP_MODE": "api",
          "AWS_REGION": "${AWS_REGION}",
          "SECRETS_PREFIX": "onboarding/"
        }
      }
    },
    "AutoDeploymentsEnabled": true
  },
  "InstanceConfiguration": {
    "Cpu": "0.25 vCPU",
    "Memory": "0.5 GB",
    "InstanceRoleArn": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/onboarding-api-role"
  }
}
EOF

aws apprunner create-service \
  --cli-input-json file:///tmp/apprunner-config.json \
  --region $AWS_REGION
```

Wait for the service to be running:

```bash
aws apprunner list-services --region $AWS_REGION \
  --query "ServiceSummaryList[?ServiceName=='ai-onboarding-api'].Status" \
  --output text
# Wait until: RUNNING

# Get the service URL
API_URL=$(aws apprunner describe-service \
  --service-arn $(aws apprunner list-services --region $AWS_REGION \
    --query "ServiceSummaryList[?ServiceName=='ai-onboarding-api'].ServiceArn" \
    --output text) \
  --query "Service.ServiceUrl" --output text)

echo "API URL: https://${API_URL}"

# Verify
curl "https://${API_URL}/health"
```

---

## 9. Deploy Workers — ECS Fargate

### Create ECS cluster

```bash
aws ecs create-cluster \
  --cluster-name onboarding-workers \
  --capacity-providers FARGATE \
  --tags key=Project,value=ai-onboarding
```

### Create CloudWatch log group

```bash
aws logs create-log-group \
  --log-group-name /ecs/onboarding-worker \
  --region $AWS_REGION
```

### Register task definition

The task definition is in `ecs_task_definition.json` (see Docker/ECS scaffold). Register it:

```bash
# Update the task definition file with your account ID and region first
sed -i "s/YOUR_ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" ecs_task_definition.json
sed -i "s/YOUR_REGION/${AWS_REGION}/g" ecs_task_definition.json

aws ecs register-task-definition \
  --cli-input-json file://ecs_task_definition.json
```

### Create ECS service

```bash
aws ecs create-service \
  --cluster onboarding-workers \
  --service-name onboarding-worker \
  --task-definition onboarding-worker \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={
    subnets=[$(echo $SUBNET_IDS | tr ',' ',')],
    securityGroups=[$SG_ID],
    assignPublicIp=ENABLED
  }"
```

---

## 10. Deploy Dashboard — AWS Amplify

1. Go to AWS Console → Amplify → New app → Host web app.
2. Connect your GitHub repository, select the `dashboard/` directory.
3. Set build settings (Amplify auto-detects Next.js).
4. Add environment variables:
   - `NEXT_PUBLIC_API_BASE_URL` → your App Runner URL (`https://...awsapprunner.com`)
   - `API_KEY` → retrieve from Secrets Manager

```bash
# Get your API key to paste into Amplify
aws secretsmanager get-secret-value \
  --secret-id "onboarding/api-key" \
  --query SecretString --output text
```

5. Deploy. Amplify provides a `*.amplifyapp.com` URL — set a custom domain under Domain Management if needed.

---

## 12. Rotating Secrets

### Rotate the API key

```bash
NEW_KEY=$(openssl rand -hex 32)

aws secretsmanager update-secret \
  --secret-id "onboarding/api-key" \
  --secret-string "$NEW_KEY"

# Force App Runner redeploy to pick up new secret
aws apprunner start-deployment \
  --service-arn $(aws apprunner list-services --region $AWS_REGION \
    --query "ServiceSummaryList[?ServiceName=='ai-onboarding-api'].ServiceArn" \
    --output text)

# Force ECS worker redeploy
aws ecs update-service \
  --cluster onboarding-workers \
  --service onboarding-worker \
  --force-new-deployment
```

Update the new key in Amplify environment variables and redeploy the dashboard.

### Rotate LLM API key

```bash
aws secretsmanager update-secret \
  --secret-id "onboarding/anthropic-api-key" \
  --secret-string "sk-ant-YOUR-NEW-KEY"

# Redeploy workers
aws ecs update-service \
  --cluster onboarding-workers \
  --service onboarding-worker \
  --force-new-deployment
```

---

## 13. Handling a Dead-Letter Queue

### Check DLQ depth

```bash
DLQ_URL=$(aws sqs get-queue-url \
  --queue-name onboarding-dead-letter \
  --query QueueUrl --output text)

aws sqs get-queue-attributes \
  --queue-url $DLQ_URL \
  --attribute-names ApproximateNumberOfMessages
```

### Inspect a failed message

```bash
aws sqs receive-message \
  --queue-url $DLQ_URL \
  --attribute-names All \
  --max-number-of-messages 1
```

### Replay a message to the original queue

```bash
# Get the message
MESSAGE=$(aws sqs receive-message \
  --queue-url $DLQ_URL \
  --query "Messages[0]" --output json)

BODY=$(echo $MESSAGE | jq -r '.Body')
RECEIPT=$(echo $MESSAGE | jq -r '.ReceiptHandle')

# Re-send to original queue (e.g. classify)
CLASSIFY_URL=$(aws sqs get-queue-url \
  --queue-name onboarding-classify \
  --query QueueUrl --output text)

aws sqs send-message \
  --queue-url $CLASSIFY_URL \
  --message-body "$BODY"

# Delete from DLQ
aws sqs delete-message \
  --queue-url $DLQ_URL \
  --receipt-handle $RECEIPT
```

---

## 14. Scaling Workers

### Scale up: increase desired count

```bash
aws ecs update-service \
  --cluster onboarding-workers \
  --service onboarding-worker \
  --desired-count 2
```

ECS Fargate scales horizontally — multiple worker tasks each poll SQS independently.

### Auto-scaling based on queue depth

```bash
# Register scalable target
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/onboarding-workers/onboarding-worker \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 1 \
  --max-capacity 5

# Create scaling policy based on SQS queue depth
# (Requires a custom CloudWatch metric — see CloudWatch Alarms section)
```

---

## 15. Incident Response Checklist

### Pipeline not processing leads

- [ ] Check App Runner service status: `aws apprunner list-services`
- [ ] Check ECS service status: `aws ecs describe-services --cluster onboarding-workers --services onboarding-worker`
- [ ] Check SQS queue depths: `aws sqs get-queue-attributes --queue-url <url> --attribute-names ApproximateNumberOfMessages`
- [ ] Check DLQ depth (section 13)
- [ ] Check CloudWatch logs: Console → CloudWatch → Log groups → `/ecs/onboarding-worker`
- [ ] Check Secrets Manager — have any secrets been accidentally deleted?

### App Runner 502 / 503 errors

- [ ] Check App Runner service logs: Console → App Runner → your service → Logs
- [ ] Check RDS connectivity: can the App Runner VPC connector reach the RDS security group?
- [ ] Check if RDS is in a maintenance window: `aws rds describe-db-instances --db-instance-identifier onboarding-db --query "DBInstances[0].PendingModifiedValues"`

### SES email not arriving

- [ ] Confirm SES is out of sandbox mode: Console → SES → Account dashboard
- [ ] Check SES sending statistics for bounces/complaints
- [ ] Verify the sending domain: `aws ses get-identity-verification-attributes --identities yourdomain.com`

---

*Last updated: April 2026 | AWS region: set via `AWS_REGION` env var*
