# Bedrock Customer Usage Skill

Codex skill for checking customer-scoped AWS Bedrock budget and usage.

The skill reports:

- AWS Budget status for a configured Bedrock customer budget
- IAM users and access keys under a configured customer path
- Bedrock usage events from CloudTrail
- CloudWatch `AWS/Bedrock` metric visibility
- Bedrock model invocation logging configuration

## Install

Copy the skill folder into your Codex skills directory:

```bash
cp -R bedrock-customer-usage ~/.codex/skills/
```

Then restart Codex if needed so the new skill is discovered.

## Configure

Use an operator AWS access key with the required read/manage permissions. You can either export the credentials directly:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=ap-southeast-1
export AWS_DEFAULT_REGION=ap-southeast-1
```

Or point the script at an env file:

```bash
export BEDROCK_USAGE_OPERATOR_CREDENTIALS=/secure/path/operator.env
```

Required configuration:

```bash
export BEDROCK_USAGE_AWS_ACCOUNT_ID=123456789012
export BEDROCK_USAGE_AWS_REGION=ap-southeast-1
export BEDROCK_USAGE_BUDGET_NAME='Customer Bedrock monthly budget'
export BEDROCK_USAGE_CUSTOMER_PATH=/bedrock-customers/customer/
```

Example credential file:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=ap-southeast-1
export AWS_DEFAULT_REGION=ap-southeast-1
```

Do not commit real credentials.

## Run

```bash
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh --hours 24
```

Useful options:

```bash
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh --hours 168 --max-pages 10 --recent 20
```

## Required AWS Permissions

The operator key should be scoped as narrowly as possible. At minimum it needs:

- `budgets:ViewBudget` for the customer budget ARN
- `iam:ListUsers` for discovery
- `iam:GetUser`, `iam:ListAccessKeys`, `iam:ListUserTags` for customer users
- `cloudtrail:LookupEvents` in the target region
- `cloudwatch:ListMetrics` in the target region
- `bedrock:GetModelInvocationLoggingConfiguration` in the target region

Optional key-management flows may also need `iam:CreateAccessKey`, `iam:UpdateAccessKey`, and `iam:DeleteAccessKey` scoped to the customer IAM path.

This skill intentionally does not require `ce:GetCostAndUsage`.
