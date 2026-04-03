#!/usr/bin/env python3
# infra/cdk/app.py
# -------------------------------------------------------------------
# CDK app entry point.
#
# Deploy:
#   pip install aws-cdk-lib constructs aws-cdk.aws-apprunner-alpha
#   cdk bootstrap
#   cdk deploy \
#     --context env=prod \
#     --context notification_email=you@yourdomain.com \
#     --context llm_provider=anthropic
# -------------------------------------------------------------------

import aws_cdk as cdk
from stack import OnboardingStack

app = cdk.App()

# Production stack
OnboardingStack(
    app,
    "OnboardingProd",
    env=cdk.Environment(
        # Reads from AWS CLI config / environment variables by default.
        # Override explicitly if needed:
        # account="123456789012",
        # region="us-east-1",
        account=app.node.try_get_context("account"),
        region=app.node.try_get_context("region"),
    ),
    description="AI Client Onboarding Pipeline — production",
)

app.synth()
