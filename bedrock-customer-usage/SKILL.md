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
- Usage: CloudTrail `LookupEvents`, filtered by customer credentials and `eventSource=bedrock.amazonaws.com`.
- Token usage: optional CloudWatch Logs Insights aggregation over Bedrock model invocation logs when `BEDROCK_USAGE_INVOCATION_LOG_GROUP` is configured.
- Key scope: IAM users under `BEDROCK_USAGE_CUSTOMER_PATH`.
- Diagnostics: `cloudwatch:ListMetrics`, `cloudwatch:GetMetricData` for returned `AWS/Bedrock` metrics, and `bedrock:GetModelInvocationLoggingConfiguration`.
- Key creation: `scripts/create_bedrock_customer_key.sh` creates one IAM user per credential and tags it for future customer-level and key-level cost attribution. It supports AWS access keys by default and Bedrock bearer API keys with `--credential-type bearer`.
- Operator smoke test: `scripts/smoke_bedrock_customer_operator.sh` creates a temporary user/credential, verifies Bedrock access, disables and deletes the temporary credential, and tries to clean up the temporary user.
- Key disable: `scripts/disable_bedrock_customer_key.sh` disables one AWS access key or Bedrock service-specific credential after verifying it belongs to the configured customer path.

## Credentials

Use the operator key for all AWS calls, including Budget, IAM key status, CloudTrail usage, CloudWatch metrics, and Bedrock logging diagnostics.

Set credentials in the environment or point `BEDROCK_USAGE_OPERATOR_CREDENTIALS` to a local env file.

The scripts auto-load shared configuration from the first file that exists:

- `./bedrock-customer-usage.env`
- `~/.config/bedrock-customer-usage/config.env`
- `bedrock-customer-usage/config.env`

Never print full `AWS_SECRET_ACCESS_KEY` or `AWS_BEARER_TOKEN_BEDROCK` values. Mask access key ids unless the user explicitly needs an exact id for AWS lookup.

Minimum create-key permissions for the default inline-policy path are:
`iam:CreateUser`, `iam:TagUser`, `iam:PutUserPolicy`, `iam:CreateAccessKey`, `iam:UpdateAccessKey`, `iam:DeleteAccessKey`, `iam:GetUser`, `iam:ListUsers`, `iam:ListAccessKeys`, and `iam:ListUserTags`, scoped to the configured customer path.

Bearer API key creation additionally needs `iam:CreateServiceSpecificCredential`, `iam:ListServiceSpecificCredentials`, `iam:UpdateServiceSpecificCredential`, and `iam:DeleteServiceSpecificCredential` scoped to the configured customer path. Creation should require `iam:ServiceSpecificCredentialServiceName=bedrock.amazonaws.com` and `iam:ServiceSpecificCredentialAgeDays <= 90`.

Usage checks need only the read-only services that are enabled in the account: Budget read, CloudTrail lookup, CloudWatch metric list/data, and Bedrock logging config. CloudWatch Logs token usage aggregation is optional and must be scoped to the Bedrock invocation log group. Raw prompt/response logs should not be printed.

## Interpretation

- Budget cost is delayed and alert-oriented. It is not a real-time meter.
- CloudTrail usage is closer to activity tracking, but still not a token or dollar cost meter.
- CloudTrail Event History is limited to recent events, normally up to 90 days.
- `cloudwatch:ListMetrics` only lists metric names/dimensions; it does not return metric values.
- `Invocation log token usage` is near-real-time token accounting from model invocation logs. It is still not invoice-accurate cost.
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

- `Customer keys`: IAM users under `BEDROCK_USAGE_CUSTOMER_PATH`, masked access key ids, masked Bedrock bearer credential ids, active/inactive status, creation date, and attribution tags.
- `CloudTrail Bedrock usage`: Bedrock events grouped by credential and model id, plus recent event names and error codes. AWS access keys are queried by `AccessKeyId`; bearer credentials are queried by IAM user name and filtered to Bedrock events.
- `Invocation log token usage`: aggregate calls and token counts grouped by IAM principal, model id, and request metadata. This section appears only when `BEDROCK_USAGE_INVOCATION_LOG_GROUP` or `--invocation-log-group` is set.
- `CloudWatch and Bedrock logging diagnostics`: whether account-level Bedrock metrics and invocation logging config are visible.

For exact language to the user:

```text
Usage here means recent Bedrock API activity from CloudTrail, grouped by customer credential. It is useful for activity/debugging, but it is not exact token or dollar cost.
```

Token-level usage by IAM user/key/model requires Bedrock invocation logging and scoped read access to the log destination. Raw CloudWatch Logs or S3 read access is not part of the default workflow because it may expose prompt/response data.

If invocation logs are enabled, run:

```bash
BEDROCK_USAGE_OPERATOR_CREDENTIALS=/secure/path/operator.env \
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh --hours 24 --invocation-log-group /aws/bedrock/model-invocations
```

The script filters results to principals under `BEDROCK_USAGE_CUSTOMER_PATH` and prints only aggregate token counts. Do not paste raw invocation log events into replies unless the user explicitly requests it and understands they may contain prompt/response data.

When callers use the Converse API, ask them to include stable `requestMetadata` such as `customer`, `usageOwner`, and `keyAlias`. If calls omit metadata, the script still groups by IAM principal ARN, which works with the one-key-per-IAM-user model.

## Create-Key Workflow

Use the create-key script when asked to provision a new Bedrock customer API key:

```bash
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh --customer example-customer --key-alias prod --output-dir ./secrets
```

For temporary tests only, `--auto-customer` may be used:

```bash
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh --auto-customer --key-alias test --output-dir ./secrets
```

Prefer an explicit stable `--customer` for production keys. Auto-generated customer names make Cost Explorer groups harder to read.

Shared path, policy, budget, and Billing View settings should come from the local config file. For daily use, provide only credentials and the customer arguments:

```bash
BEDROCK_KEY_OPERATOR_CREDENTIALS=/secure/path/operator.env
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh --customer example-customer --key-alias prod --output-dir ./secrets
```

Keep the invariant: one credential equals one IAM user. The script tags each IAM user with `customer` and `usageOwner`; those tags are intended for future AWS cost allocation after activation.

By default, the script creates an AWS access key pair and uses `iam:PutUserPolicy` to add a small inline policy for Bedrock list/invoke/converse. Managed runtime policy attachment and permissions boundaries are optional config values, not required for the default path.

If a caller needs a Bedrock bearer API key, create it explicitly:

```bash
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh --customer example-customer --key-alias prod --credential-type bearer --bearer-token-days 90 --output-dir ./secrets
```

This uses `iam:CreateServiceSpecificCredential` for `bedrock.amazonaws.com`, writes `AWS_BEARER_TOKEN_BEDROCK` to the local `0600` env file, and verifies with the Bedrock Converse API. The runtime policy must include `bedrock:CallWithBearerToken`.

For a full operator check, run:

```bash
bedrock-customer-usage/scripts/smoke_bedrock_customer_operator.sh
```

For disabling a customer key:

```bash
bedrock-customer-usage/scripts/disable_bedrock_customer_key.sh --access-key-id AKIA...
```

For disabling a Bedrock bearer API key:

```bash
bedrock-customer-usage/scripts/disable_bedrock_customer_key.sh --service-credential-id ACCA...
```

## Safety Boundary

Do not add account-wide Cost Explorer or broader CloudWatch Logs read permissions unless the user explicitly approves after the account-level visibility risk is explained.

Scoped Cost Explorer is acceptable only when all of these are true:

- The API call includes `--billing-view-arn`.
- The Billing View is filtered to the intended customer scope.
- IAM permissions for `ce:GetCostAndUsage`, `ce:GetTags`, `ce:GetDimensionValues`, and `billing:GetBillingView` are scoped to that Billing View ARN.
