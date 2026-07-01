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
- Diagnostics: `cloudwatch:ListMetrics`, `cloudwatch:GetMetricData` for returned `AWS/Bedrock` metrics, and `bedrock:GetModelInvocationLoggingConfiguration`.
- Key creation: `scripts/create_bedrock_customer_key.sh` creates one IAM user per access key and tags it for future customer-level and key-level cost attribution.
- Operator smoke test: `scripts/smoke_bedrock_customer_operator.sh` creates a temporary user/key, verifies Bedrock list/invoke, disables and deletes the temporary access key, and tries to clean up the temporary user.
- Key disable: `scripts/disable_bedrock_customer_key.sh` disables one key after verifying it belongs to the configured customer path.

## Credentials

Use the operator key for all AWS calls, including Budget, IAM key status, CloudTrail usage, CloudWatch metrics, and Bedrock logging diagnostics.

Set credentials in the environment or point `BEDROCK_USAGE_OPERATOR_CREDENTIALS` to a local env file.

The scripts auto-load shared configuration from the first file that exists:

- `./bedrock-customer-usage.env`
- `~/.config/bedrock-customer-usage/config.env`
- `bedrock-customer-usage/config.env`

Never print full `AWS_SECRET_ACCESS_KEY` values. Mask access key ids unless the user explicitly needs an exact id for AWS lookup.

Minimum create-key permissions for the default inline-policy path are:
`iam:CreateUser`, `iam:TagUser`, `iam:PutUserPolicy`, `iam:CreateAccessKey`, `iam:UpdateAccessKey`, `iam:DeleteAccessKey`, `iam:GetUser`, `iam:ListUsers`, `iam:ListAccessKeys`, and `iam:ListUserTags`, scoped to the configured customer path.

Usage checks need only the read-only services that are enabled in the account: Budget read, CloudTrail lookup, CloudWatch metric list/data, and Bedrock logging config. Raw CloudWatch Logs or S3 invocation logs are not part of the default path.

## Interpretation

- Budget cost is delayed and alert-oriented. It is not a real-time meter.
- CloudTrail usage is closer to activity tracking, but still not a token or dollar cost meter.
- CloudTrail Event History is limited to recent events, normally up to 90 days.
- `cloudwatch:ListMetrics` only lists metric names/dimensions; it does not return metric values.
- If the user asks for exact customer cost by key, say that the clean path is the customer Budget tag filter plus CloudTrail usage, not raw `ce:GetCostAndUsage`.
- If a customer-scoped Billing View ARN is configured, the operator may query Cost Explorer through that view only.
- The operator should be able to view only the customer Budget alert and the scoped Billing View, not broad Cost Explorer data.

## Cost Check Workflow

Use this workflow when the user asks for spend, cost, budget, alert status, monthly total, or per-customer/per-key cost.

Run:

```bash
BEDROCK_USAGE_OPERATOR_CREDENTIALS=/secure/path/operator.env \
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh --hours 24
```

Read these output sections:

- `Budget cost`: budget name, monthly limit, actual spend, tag filters, service filters, and notification states.
- `Scoped Cost Explorer`: current-month Bedrock `UnblendedCost` and `UsageQuantity` through `BEDROCK_USAGE_BILLING_VIEW_ARN`, plus grouping by `user:iamPrincipal/customer` and `user:iamPrincipal/usageOwner`.
- `total_unblended_cost=unavailable`: usually means the operator lacks scoped Cost Explorer/Billing View permissions or the Billing View ARN is not configured.
- `actual=0` or missing tag groups: can be normal for new keys because AWS billing and cost allocation tags are delayed.

For exact language to the user:

```text
Cost is billing-delayed. The dashboard/script can show current Budget and scoped Cost Explorer totals, but recent calls may show in CloudTrail before dollars appear in Cost Explorer.
```

Do not claim per-key cost exists unless `usageOwner` cost allocation tags are active and Cost Explorer returns grouped data for that tag.

## Usage Check Workflow

Use this workflow when the user asks who used the key, whether a key is active, which model was called, or whether a customer key recently invoked Bedrock.

Run:

```bash
BEDROCK_USAGE_OPERATOR_CREDENTIALS=/secure/path/operator.env \
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh --hours 168 --recent 20
```

Read these output sections:

- `Customer keys`: IAM users under `BEDROCK_USAGE_CUSTOMER_PATH`, masked access key ids, active/inactive status, creation date, and attribution tags.
- `CloudTrail Bedrock usage`: Bedrock events grouped by access key and model id, plus recent event names and error codes.
- `CloudWatch and Bedrock logging diagnostics`: whether account-level Bedrock metrics and invocation logging config are visible.

For exact language to the user:

```text
Usage here means recent Bedrock API activity from CloudTrail, grouped by customer access key. It is useful for activity/debugging, but it is not exact token or dollar cost.
```

Token-level usage by IAM user/key/model requires Bedrock invocation logging and scoped read access to the log destination. Raw CloudWatch Logs or S3 read access is not part of the default workflow because it may expose prompt/response data.

## Create-Key Workflow

Use the create-key script when asked to provision a new Bedrock customer API key:

```bash
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh --customer example-customer --key-alias prod --output-dir ./secrets
```

Shared path, policy, budget, and Billing View settings should come from the local config file. For daily use, provide only credentials and the customer arguments:

```bash
BEDROCK_KEY_OPERATOR_CREDENTIALS=/secure/path/operator.env
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh --customer example-customer --key-alias prod --output-dir ./secrets
```

Keep the invariant: one access key equals one IAM user. The script tags each IAM user with `customer` and `usageOwner`; those tags are intended for future AWS cost allocation after activation.

By default, the script uses `iam:PutUserPolicy` to add a small inline policy for Bedrock list/invoke/converse. Managed runtime policy attachment and permissions boundaries are optional config values, not required for the default path.

If someone asks for `iam:CreateServiceSpecificCredential`, clarify that Bedrock SDK/CLI/server access uses normal IAM access key plus secret key credentials. Service-specific credentials are not the right mechanism for Bedrock runtime calls.

For a full operator check, run:

```bash
bedrock-customer-usage/scripts/smoke_bedrock_customer_operator.sh
```

For disabling a customer key:

```bash
bedrock-customer-usage/scripts/disable_bedrock_customer_key.sh --access-key-id AKIA...
```

## Safety Boundary

Do not add account-wide Cost Explorer or broader CloudWatch Logs read permissions unless the user explicitly approves after the account-level visibility risk is explained.

Scoped Cost Explorer is acceptable only when all of these are true:

- The API call includes `--billing-view-arn`.
- The Billing View is filtered to the intended customer scope.
- IAM permissions for `ce:GetCostAndUsage`, `ce:GetTags`, `ce:GetDimensionValues`, and `billing:GetBillingView` are scoped to that Billing View ARN.
