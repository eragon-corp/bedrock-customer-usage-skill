# AWS Runbook: Customer-Scoped Bedrock Keys

This runbook describes how to operate customer-scoped AWS Bedrock credentials
with least-privilege IAM, budget visibility, and usage checks.

Use placeholders in this document as-is. Do not commit real account ids,
customer names, access keys, or secret keys.

## Goal

Provision one Bedrock credential per downstream customer or customer workload,
while keeping each credential attributable and easy to disable.

The operating model is:

```text
one customer credential = one IAM user = one AWS access key pair or Bedrock bearer credential
```

Each IAM user is created under a customer path such as:

```text
/bedrock-customers/customer/
```

Each IAM user is tagged for cost and activity attribution:

```text
customer=<customer-slug>
usageOwner=<customer-slug>-<key-alias>-<timestamp>
keyAlias=<key-alias>
Purpose=<customer-scope>
owner=<owner-scope>
budgetScope=bedrock
region=ap-southeast-1
```

## Prerequisites

- AWS CLI v2
- `jq`
- `python3`
- A Bedrock-enabled AWS account
- Bedrock model access enabled in the target region
- An operator IAM user or role dedicated to this workflow
- Optional: AWS Budget configured for the customer scope
- Optional: AWS Billing View scoped to the customer cost tags

## Region

Use the Bedrock region required by the customer. Example:

```bash
export AWS_REGION=ap-southeast-1
export AWS_DEFAULT_REGION=ap-southeast-1
```

## Bootstrap AWS IAM

Create a dedicated operator principal. Do not use an admin key for daily
customer key creation.

The operator should be able to manage only IAM users under the configured
customer path. Actions that AWS does not support with resource-level scoping
must use `Resource: "*"`, so keep this operator key narrow and separate from
admin credentials.

Example operator policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageCustomerUsersInPath",
      "Effect": "Allow",
      "Action": [
        "iam:CreateUser",
        "iam:TagUser",
        "iam:PutUserPolicy",
        "iam:CreateAccessKey",
        "iam:UpdateAccessKey",
        "iam:DeleteAccessKey",
        "iam:GetUser",
        "iam:ListAccessKeys",
        "iam:ListUserTags"
      ],
      "Resource": "arn:aws:iam::<account-id>:user/bedrock-customers/customer/*"
    },
    {
      "Sid": "CreateBedrockBearerCredentialsInPath",
      "Effect": "Allow",
      "Action": "iam:CreateServiceSpecificCredential",
      "Resource": "arn:aws:iam::<account-id>:user/bedrock-customers/customer/*",
      "Condition": {
        "StringEquals": {
          "iam:ServiceSpecificCredentialServiceName": "bedrock.amazonaws.com"
        },
        "NumericLessThanEquals": {
          "iam:ServiceSpecificCredentialAgeDays": "365"
        },
        "Null": {
          "iam:ServiceSpecificCredentialAgeDays": "false"
        }
      }
    },
    {
      "Sid": "ManageBedrockBearerCredentialsInPath",
      "Effect": "Allow",
      "Action": [
        "iam:ListServiceSpecificCredentials",
        "iam:UpdateServiceSpecificCredential",
        "iam:DeleteServiceSpecificCredential"
      ],
      "Resource": "arn:aws:iam::<account-id>:user/bedrock-customers/customer/*"
    },
    {
      "Sid": "ListUsersForPathDiscovery",
      "Effect": "Allow",
      "Action": "iam:ListUsers",
      "Resource": "*"
    },
    {
      "Sid": "ReadUsageSignals",
      "Effect": "Allow",
      "Action": [
        "cloudtrail:LookupEvents",
        "cloudwatch:ListMetrics",
        "cloudwatch:GetMetricData",
        "bedrock:GetModelInvocationLoggingConfiguration"
      ],
      "Resource": "*"
    },
    {
      "Sid": "StartBedrockInvocationLogTokenQuery",
      "Effect": "Allow",
      "Action": "logs:StartQuery",
      "Resource": "arn:aws:logs:<region>:<account-id>:log-group:<bedrock-invocation-log-group>:*"
    },
    {
      "Sid": "ReadBedrockInvocationLogTokenQueryResults",
      "Effect": "Allow",
      "Action": "logs:GetQueryResults",
      "Resource": "*"
    },
    {
      "Sid": "ReadBudgetStatus",
      "Effect": "Allow",
      "Action": [
        "budgets:DescribeBudget",
        "budgets:DescribeNotificationsForBudget"
      ],
      "Resource": "*"
    }
  ]
}
```

Optional scoped Cost Explorer read policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadScopedBillingView",
      "Effect": "Allow",
      "Action": "billing:GetBillingView",
      "Resource": "arn:aws:billing::<account-id>:billingview/custom-..."
    },
    {
      "Sid": "ReadCostExplorer",
      "Effect": "Allow",
      "Action": [
        "ce:GetCostAndUsage",
        "ce:GetTags",
        "ce:GetDimensionValues"
      ],
      "Resource": "*"
    }
  ]
}
```

When Cost Explorer access is enabled, always call it with the configured
`--billing-view-arn`. That keeps the query result scoped even when Cost Explorer
actions require broad IAM resources.

Optional cleanup permissions for the smoke test:

```json
{
  "Effect": "Allow",
  "Action": [
    "iam:DeleteAccessKey",
    "iam:DeleteServiceSpecificCredential",
    "iam:DeleteUserPolicy",
    "iam:DeleteUser"
  ],
  "Resource": "arn:aws:iam::<account-id>:user/bedrock-customers/customer/*"
}
```

If you do not grant the optional cleanup permissions, the smoke test still
disables and deletes the temporary credential when allowed, then prints the
admin cleanup commands for the temporary IAM user if user cleanup is blocked.

## Bootstrap Cost Attribution

For customer-level and key-level cost reporting, activate these IAM principal
tags as AWS cost allocation tags:

```text
user:iamPrincipal/customer
user:iamPrincipal/usageOwner
```

AWS billing and cost allocation tags are delayed. New tags and new cost groups
may take hours before they appear in Cost Explorer or Budgets.

Recommended budget setup:

```text
Budget type: Cost budget
Scope: Bedrock service usage
Filter: customer tag or usageOwner tag
Threshold: your monthly limit
Notifications: email or SNS
```

If you need to let the operator query cost, prefer a customer-scoped Billing
View instead of broad Cost Explorer permissions.

## Configure the Skill

Install the skill:

```bash
cp -R bedrock-customer-usage ~/.codex/skills/
```

Create a local config:

```bash
mkdir -p ~/.config/bedrock-customer-usage
cp bedrock-customer-usage/config.example.env ~/.config/bedrock-customer-usage/config.env
```

Edit the local config:

```bash
export BEDROCK_USAGE_AWS_ACCOUNT_ID=123456789012
export BEDROCK_USAGE_AWS_REGION=ap-southeast-1
export BEDROCK_USAGE_BUDGET_NAME='Customer Bedrock monthly budget'
export BEDROCK_USAGE_CUSTOMER_PATH=/bedrock-customers/customer/
export BEDROCK_USAGE_BILLING_VIEW_ARN=arn:aws:billing::123456789012:billingview/custom-...
export BEDROCK_USAGE_INVOCATION_LOG_GROUP=/aws/bedrock/model-invocations

export BEDROCK_KEY_CUSTOMER_PATH=/bedrock-customers/customer/
export BEDROCK_KEY_OWNER=customer-owner
export BEDROCK_KEY_PURPOSE=customer-purpose
export BEDROCK_KEY_REGION=ap-southeast-1
export BEDROCK_KEY_VERIFY_MODEL_ID=anthropic.claude-3-haiku-20240307-v1:0
# Optional; default is access-key.
# export BEDROCK_KEY_CREDENTIAL_TYPE=access-key
# export BEDROCK_KEY_BEARER_TOKEN_DAYS=365
```

Put the operator credential in a private env file outside the repo:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=ap-southeast-1
export AWS_DEFAULT_REGION=ap-southeast-1
```

## Smoke Test the Operator

Run:

```bash
export BEDROCK_KEY_OPERATOR_CREDENTIALS=/secure/path/operator.env
bedrock-customer-usage/scripts/smoke_bedrock_customer_operator.sh
```

Expected result:

```text
creating_user=bedrock-smoke-...
credential_type=access-key
runtime_policy=inline:BedrockCustomerRuntime
bedrock_model_count=<number>
bedrock_invoke_response=ok
s3=denied_ok
smoke_result=ok
```

To test Bedrock bearer API keys:

```bash
bedrock-customer-usage/scripts/smoke_bedrock_customer_operator.sh \
  --credential-type bearer \
  --bearer-token-days 1
```

Expected bearer result:

```text
credential_type=bearer
bedrock_converse_response=Ok.
s3=not_applicable_for_bearer
smoke_result=ok
```

If cleanup is manual, run the printed admin cleanup commands after confirming
the temporary credential was disabled and deleted.

## Create a Customer Key

Run:

```bash
export BEDROCK_KEY_OPERATOR_CREDENTIALS=/secure/path/operator.env
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh \
  --customer example-customer \
  --key-alias prod \
  --output-dir ./secrets
```

For a temporary test key, generate a customer tag automatically:

```bash
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh \
  --auto-customer \
  --key-alias test \
  --output-dir ./secrets
```

Use `--auto-customer` only for smoke tests or temporary keys. Production keys
should use a stable `--customer` value so customer and per-key cost groups remain
readable in Cost Explorer.

The script creates:

- One IAM user under the configured path
- One inline Bedrock runtime policy
- One credential: AWS access key pair by default, or Bedrock bearer credential
  when requested
- One local `0600` env file with the customer credential
- Tags for both customer grouping and per-key grouping

For the default access-key path, the customer receives:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=ap-southeast-1
export AWS_DEFAULT_REGION=ap-southeast-1
```

If the customer specifically needs a Bedrock bearer API key, run:

```bash
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh \
  --customer example-customer \
  --key-alias prod \
  --credential-type bearer \
  --bearer-token-days 365 \
  --output-dir ./secrets
```

The customer receives:

```bash
export AWS_BEARER_TOKEN_BEDROCK=...
export AWS_REGION=ap-southeast-1
export AWS_DEFAULT_REGION=ap-southeast-1
```

Bearer API keys are IAM service-specific credentials for
`bedrock.amazonaws.com`. The customer runtime policy must allow
`bedrock:CallWithBearerToken`, and the operator create permission should require
`iam:ServiceSpecificCredentialAgeDays <= 365`.

## Verify a Customer Key Manually

With the generated customer credential loaded:

```bash
aws bedrock list-foundation-models \
  --region ap-southeast-1 \
  --query 'length(modelSummaries)' \
  --output text
```

Invoke a small model:

```bash
jq -nc '{
  anthropic_version: "bedrock-2023-05-31",
  max_tokens: 4,
  messages: [
    {
      role: "user",
      content: [{type: "text", text: "Reply with ok."}]
    }
  ]
}' > /tmp/bedrock-smoke-body.json

aws bedrock-runtime invoke-model \
  --region ap-southeast-1 \
  --model-id anthropic.claude-3-haiku-20240307-v1:0 \
  --content-type application/json \
  --accept application/json \
  --body fileb:///tmp/bedrock-smoke-body.json \
  /tmp/bedrock-smoke-response.json

jq -r '.content[]? | select(.type=="text") | .text' /tmp/bedrock-smoke-response.json
```

Expected output:

```text
ok
```

Confirm unrelated AWS services are denied:

```bash
aws s3 ls
```

Expected result: access denied.

For a Bedrock bearer API key, verify with the Converse endpoint instead:

```bash
jq -nc '{
  messages: [
    {
      role: "user",
      content: [{text: "Reply with ok."}]
    }
  ],
  inferenceConfig: {maxTokens: 4}
}' > /tmp/bedrock-converse-body.json

curl -sS \
  -X POST "https://bedrock-runtime.ap-southeast-1.amazonaws.com/model/anthropic.claude-3-haiku-20240307-v1%3A0/converse" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AWS_BEARER_TOKEN_BEDROCK" \
  --data-binary @/tmp/bedrock-converse-body.json \
  | jq -r '.output.message.content[]? | .text // empty'
```

Bearer API keys may need a short propagation delay after creation. The script
handles this with retries.

## Check Cost

Cost checks answer:

```text
How much has this customer scope spent this month?
Is the monthly budget alert configured and healthy?
Can cost be grouped by customer or per-key usageOwner tags?
```

Run the bundled checker:

```bash
export BEDROCK_USAGE_OPERATOR_CREDENTIALS=/secure/path/operator.env
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh --hours 24
```

The cost sections in the output are:

```text
== Budget cost ==
budget=<budget-name>
limit=<amount> USD / MONTHLY
actual=<amount> USD
tag_filter=<budget tag filters>
service_filters_count=<number>
notifications=
  ACTUAL GREATER_THAN <threshold>% state=<state>

== Scoped Cost Explorer ==
period=<month-start>..<tomorrow>
service=Amazon Bedrock
billing_view=<billing-view-arn>
total_unblended_cost=<amount> USD estimated=<true|false>
by_customer_groups=<number>
by_usageOwner_groups=<number>
```

If `BEDROCK_USAGE_BILLING_VIEW_ARN` is not configured, Budget status still
works, but scoped Cost Explorer totals are skipped.

Important cost limitations:

- Budgets and Cost Explorer are delayed billing views.
- A new IAM tag may not appear as a cost allocation tag immediately.
- A new access key can have CloudTrail usage before any cost appears.
- Per-key cost requires one key per IAM user and active cost allocation tags
  such as `user:iamPrincipal/usageOwner`.

Direct AWS CLI checks for administrators:

```bash
aws budgets describe-budget \
  --account-id 123456789012 \
  --budget-name 'Customer Bedrock monthly budget'

aws budgets describe-notifications-for-budget \
  --account-id 123456789012 \
  --budget-name 'Customer Bedrock monthly budget'
```

With a Billing View:

```bash
aws ce get-cost-and-usage \
  --billing-view-arn arn:aws:billing::123456789012:billingview/custom-... \
  --time-period Start=2026-07-01,End=2026-07-02 \
  --granularity MONTHLY \
  --metrics UnblendedCost UsageQuantity \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Bedrock"]}}' \
  --region us-east-1
```

## Check Usage

Usage checks answer:

```text
Which customer keys exist?
Which keys are active or inactive?
Which keys recently called Bedrock?
Which model ids were called?
Were there Bedrock errors?
Are CloudWatch Bedrock metrics and invocation logging visible?
If configured, how many input/output/cache tokens were logged?
```

Run a short CloudTrail window:

```bash
export BEDROCK_USAGE_OPERATOR_CREDENTIALS=/secure/path/operator.env
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh --hours 24
```

Run a larger CloudTrail window:

```bash
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh --hours 168 --recent 20
```

The usage sections in the output are:

```text
== Customer keys ==
users=<count> path=<customer-path>
user=<iam-user> key=<masked-key> status=<Active|Inactive> created=<date> customer=<tag> usageOwner=<tag>

== CloudTrail Bedrock usage ==
bedrock_events=<count>
by_key=
  key=<masked-key> user=<iam-user> events=<count> errors=<count>
by_model=
  model=<model-id> events=<count>
recent=
  <event-time> <event-name> key=<masked-key> model=<model-id> error=<error-code|none>

== CloudWatch and Bedrock logging diagnostics ==
cloudwatch_list_metrics=<ok|unavailable> count=<count>
cloudwatch_get_metric_data=<ok|unavailable|skipped>
bedrock_invocation_logging=<ok|unavailable>

== Invocation log token usage ==
invocation_log_group=<log-group-name>
query_status=Complete
raw_groups=<number> scoped_groups=<number>
total_calls=<number> input_tokens=<number> output_tokens=<number> cache_read_tokens=<number> cache_write_tokens=<number>
by_principal_model=
  user=<iam-user> customer=<metadata-or-> usageOwner=<metadata-or-> keyAlias=<metadata-or-> model=<model-id> calls=<number> input=<number> output=<number> cacheRead=<number> cacheWrite=<number>
```

Important usage limitations:

- CloudTrail is better for recent activity by access key.
- CloudTrail Event History is limited and normally covers recent events only.
- CloudTrail tells you calls, models, and errors; it is not an exact cost meter.
- CloudWatch metrics are account/model-level signals, not guaranteed per key.
- Invocation log token usage is near-real-time token accounting, not invoice
  cost. It requires Bedrock model invocation logging and scoped read access to
  the chosen log destination.
- The script filters CloudWatch Logs Insights results to principals under
  `BEDROCK_USAGE_CUSTOMER_PATH` and prints aggregates only, not prompt/response
  bodies.

Direct AWS CLI checks for administrators:

```bash
aws iam list-users \
  --path-prefix /bedrock-customers/customer/

aws iam list-access-keys \
  --user-name <customer-iam-user>

aws iam list-user-tags \
  --user-name <customer-iam-user>

aws cloudtrail lookup-events \
  --region ap-southeast-1 \
  --lookup-attributes AttributeKey=AccessKeyId,AttributeValue=<access-key-id> \
  --start-time 2026-07-01T00:00:00Z \
  --end-time 2026-07-02T00:00:00Z \
  --max-results 50

aws cloudwatch list-metrics \
  --region ap-southeast-1 \
  --namespace AWS/Bedrock

aws bedrock get-model-invocation-logging-configuration \
  --region ap-southeast-1
```

Token usage from CloudWatch Logs invocation logs:

```bash
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh \
  --hours 24 \
  --invocation-log-group /aws/bedrock/model-invocations
```

When callers use the Converse API, include stable request metadata so token
usage can be grouped by customer and key alias:

```json
{
  "modelId": "anthropic.claude-3-haiku-20240307-v1:0",
  "requestMetadata": {
    "customer": "example-customer",
    "usageOwner": "example-customer-prod-20260701T000000Z",
    "keyAlias": "prod"
  },
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "text": "Reply with ok."
        }
      ]
    }
  ],
  "inferenceConfig": {
    "maxTokens": 4
  }
}
```

If calls omit request metadata, the invocation log query still groups by
`identity.arn`. This remains useful when each customer key maps to exactly one
IAM user.

## Disable a Customer Key

Run:

```bash
export BEDROCK_KEY_OPERATOR_CREDENTIALS=/secure/path/operator.env
bedrock-customer-usage/scripts/disable_bedrock_customer_key.sh \
  --access-key-id AKIA...
```

The script first resolves the key under the configured customer path, then runs:

```bash
aws iam update-access-key \
  --user-name <customer-user> \
  --access-key-id <access-key-id> \
  --status Inactive
```

It does not delete the IAM user or the access key.

For a Bedrock bearer API key:

```bash
bedrock-customer-usage/scripts/disable_bedrock_customer_key.sh \
  --service-credential-id ACCA...
```

The script resolves the service-specific credential under the configured
customer path, then runs:

```bash
aws iam update-service-specific-credential \
  --user-name <customer-user> \
  --service-specific-credential-id <service-credential-id> \
  --status Inactive
```

It does not delete the IAM user or the service-specific credential.

## Optional: Invocation Logging

Enable Bedrock model invocation logging only after deciding what data may be
stored. Invocation logs can contain prompts, responses, metadata, and token
counts depending on configuration.

If logs are stored in CloudWatch Logs, grant only the specific log group:

```text
logs:StartQuery
logs:GetQueryResults
```

The usage script uses Logs Insights aggregate queries and does not print raw log
events. Avoid `logs:FilterLogEvents` unless a human has explicitly accepted the
risk of exposing prompt/response data.

If logs are stored in S3, grant only the Bedrock invocation log bucket/prefix:

```text
s3:ListBucket
s3:GetObject
```

Do not grant broad account-wide CloudWatch Logs or S3 read access unless the
visibility risk is explicitly accepted.

## Troubleshooting

`iam:CreateServiceSpecificCredential` failed:

Use this action only for Bedrock bearer API keys. Check that the operator is
creating credentials for `bedrock.amazonaws.com`, that
`CredentialAgeDays` is present and no more than 365, and that the target IAM user
is under the configured customer path with the required tags.

Model list succeeds but model invoke fails:

Check the exact Bedrock model id, region, and model access status. UI aliases
such as `claude-sonnet-...` may need to map to official Bedrock ids such as
`anthropic...` or inference profile ids.

Budget shows zero or unavailable:

Budget data is delayed. Confirm the budget filter, activated cost allocation
tags, and Billing View scope. Use CloudTrail for recent activity checks.

CloudTrail shows no events:

Confirm you are checking the same region where Bedrock was called, and increase
the `--hours` window. CloudTrail Event History is limited and not a permanent
usage ledger.

Smoke test leaves a temporary IAM user:

The operator can usually disable/delete the temporary credential, but may not
have user delete permissions. Run the printed admin cleanup commands.
