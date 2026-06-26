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
- Scoped Cost Explorer: if `BEDROCK_USAGE_BILLING_VIEW_ARN` is set, query only that Billing View and group Bedrock cost by customer and usage-owner tags.
- Usage: CloudTrail `LookupEvents`, filtered by customer access keys and `eventSource=bedrock.amazonaws.com`.
- Key scope: IAM users under `BEDROCK_USAGE_CUSTOMER_PATH`.
- Diagnostics: `cloudwatch:ListMetrics` for `AWS/Bedrock` and `bedrock:GetModelInvocationLoggingConfiguration`.
- Key creation: `scripts/create_bedrock_customer_key.sh` creates one IAM user per access key and tags it for future customer-level and key-level cost attribution.

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
- If a customer-scoped Billing View ARN is configured, the operator may query Cost Explorer through that view only.
- The operator should be able to view only the customer Budget alert and the scoped Billing View, not broad Cost Explorer data.

## Create-Key Workflow

Use the create-key script when asked to provision a new Bedrock customer API key:

```bash
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh --customer example-customer --key-alias prod --output-dir ./secrets
```

Provide configuration with environment variables:

```bash
BEDROCK_KEY_OPERATOR_CREDENTIALS=/secure/path/operator.env
BEDROCK_KEY_CUSTOMER_PATH=/bedrock-customers/customer/
BEDROCK_KEY_OWNER=customer-owner
BEDROCK_KEY_PURPOSE=customer-purpose
BEDROCK_KEY_REGION=ap-southeast-1
BEDROCK_KEY_RUNTIME_POLICY_ARN=arn:aws:iam::123456789012:policy/RuntimePolicy
BEDROCK_KEY_BOUNDARY_POLICY_ARN=arn:aws:iam::123456789012:policy/BoundaryPolicy
```

Keep the invariant: one access key equals one IAM user. The script tags each IAM user with `customer` and `usageOwner`; those tags are intended for future AWS cost allocation after activation.

## Safety Boundary

Do not add account-wide Cost Explorer or broader CloudWatch Logs read permissions unless the user explicitly approves after the account-level visibility risk is explained.

Scoped Cost Explorer is acceptable only when all of these are true:

- The API call includes `--billing-view-arn`.
- The Billing View is filtered to the intended customer scope.
- IAM permissions for `ce:GetCostAndUsage`, `ce:GetTags`, `ce:GetDimensionValues`, and `billing:GetBillingView` are scoped to that Billing View ARN.
