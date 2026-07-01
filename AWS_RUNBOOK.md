# AWS Runbook: Customer-Scoped Bedrock Keys

This runbook describes how to operate customer-scoped AWS Bedrock access keys
with least-privilege IAM, budget visibility, and usage checks.

Use placeholders in this document as-is. Do not commit real account ids,
customer names, access keys, or secret keys.

## Goal

Provision one Bedrock access key per downstream customer or customer workload,
while keeping each key attributable and easy to disable.

The operating model is:

```text
one customer key = one IAM user = one AWS access key pair
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

Optional cleanup permissions for the smoke test:

```json
{
  "Effect": "Allow",
  "Action": [
    "iam:DeleteUserPolicy",
    "iam:DeleteUser"
  ],
  "Resource": "arn:aws:iam::<account-id>:user/bedrock-customers/customer/*"
}
```

If you do not grant the optional cleanup permissions, the smoke test still
disables and deletes the temporary access key, then prints the admin cleanup
commands for the temporary IAM user.

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

export BEDROCK_KEY_CUSTOMER_PATH=/bedrock-customers/customer/
export BEDROCK_KEY_OWNER=customer-owner
export BEDROCK_KEY_PURPOSE=customer-purpose
export BEDROCK_KEY_REGION=ap-southeast-1
export BEDROCK_KEY_VERIFY_MODEL_ID=anthropic.claude-3-haiku-20240307-v1:0
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
runtime_policy=inline:BedrockCustomerRuntime
bedrock_model_count=<number>
bedrock_invoke_response=ok
s3=denied_ok
smoke_result=ok
```

If cleanup is manual, run the printed admin cleanup commands after confirming
the temporary access key was disabled and deleted.

## Create a Customer Key

Run:

```bash
export BEDROCK_KEY_OPERATOR_CREDENTIALS=/secure/path/operator.env
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh \
  --customer example-customer \
  --key-alias prod \
  --output-dir ./secrets
```

The script creates:

- One IAM user under the configured path
- One inline Bedrock runtime policy
- One access key pair
- One local `0600` env file with the customer credential

The customer receives:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=ap-southeast-1
export AWS_DEFAULT_REGION=ap-southeast-1
```

Bedrock uses normal IAM access key and secret key credentials. Do not use
`iam:CreateServiceSpecificCredential` for Bedrock runtime access.

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

## Check Usage

Run:

```bash
export BEDROCK_USAGE_OPERATOR_CREDENTIALS=/secure/path/operator.env
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh --hours 24
```

For a larger CloudTrail window:

```bash
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh --hours 168 --recent 20
```

Interpretation:

- Budget and Cost Explorer are delayed billing views.
- CloudTrail is better for recent activity by access key.
- CloudWatch metrics are account/model-level signals, not guaranteed per key.
- Exact token-level usage by IAM user/key/model requires Bedrock invocation
  logging and scoped read access to the chosen log destination.

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

## Optional: Invocation Logging

Enable Bedrock model invocation logging only after deciding what data may be
stored. Invocation logs can contain prompts, responses, metadata, and token
counts depending on configuration.

If logs are stored in CloudWatch Logs, grant only the specific log group:

```text
logs:DescribeLogGroups
logs:DescribeLogStreams
logs:FilterLogEvents
logs:StartQuery
logs:GetQueryResults
```

If logs are stored in S3, grant only the Bedrock invocation log bucket/prefix:

```text
s3:ListBucket
s3:GetObject
```

Do not grant broad account-wide CloudWatch Logs or S3 read access unless the
visibility risk is explicitly accepted.

## Troubleshooting

`iam:CreateServiceSpecificCredential` failed:

Bedrock does not need service-specific credentials. Use normal IAM access key
and secret key credentials.

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

The operator can disable/delete the temporary access key, but may not have user
delete permissions. Run the printed admin cleanup commands.
