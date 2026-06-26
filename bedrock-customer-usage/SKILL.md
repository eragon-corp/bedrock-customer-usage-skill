---
name: bedrock-customer-usage
description: Check customer-scoped AWS Bedrock cost and usage. Use when asked to inspect Bedrock spend, budget status, CloudTrail usage, Bedrock customer key activity, scoped IAM customer users, or a monthly Bedrock budget alert.
---

# Bedrock Customer Usage

## Quick Start

Run the bundled script first:

```bash
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh --hours 24
```

Use a longer CloudTrail window when needed:

```bash
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh --hours 168
```

## What It Checks

- Cost: AWS Budgets entry configured by `BEDROCK_USAGE_BUDGET_NAME`.
- Cost filter: usually a customer cost allocation tag plus Bedrock service filters.
- Usage: CloudTrail `LookupEvents`, filtered by customer access keys and `eventSource=bedrock.amazonaws.com`.
- Key scope: IAM users under `BEDROCK_USAGE_CUSTOMER_PATH`.
- Diagnostics: `cloudwatch:ListMetrics` for `AWS/Bedrock` and `bedrock:GetModelInvocationLoggingConfiguration`.

## Credentials

Use the operator key for all AWS calls, including Budget, IAM key status, CloudTrail usage, CloudWatch metrics, and Bedrock logging diagnostics.

Set credentials in the environment or point `BEDROCK_USAGE_OPERATOR_CREDENTIALS` to a local env file.

Never print full `AWS_SECRET_ACCESS_KEY` values. Mask access key ids unless the user explicitly needs an exact id for AWS lookup.

## Interpretation

- Budget cost is delayed and alert-oriented. It is not a real-time meter.
- CloudTrail usage is closer to activity tracking, but still not a token or dollar cost meter.
- CloudTrail Event History is limited to recent events, normally up to 90 days.
- `cloudwatch:ListMetrics` only lists metric names/dimensions; it does not return metric values.
- If the user asks for exact customer cost by key, say that the clean path is the customer Budget tag filter plus CloudTrail usage, not raw `ce:GetCostAndUsage`.
- The operator should be able to view only the customer Budget alert, not broad Cost Explorer data.

## Safety Boundary

Do not add `ce:GetCostAndUsage` or broader CloudWatch Logs read permissions unless the user explicitly approves after the account-level visibility risk is explained.
