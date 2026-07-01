# Bedrock Customer Usage Skill

Use this skill to manage customer-scoped AWS Bedrock credentials and check their
usage from Codex.

For the AWS-side setup and operating procedure, see [AWS_RUNBOOK.md](AWS_RUNBOOK.md).

It helps you:

- Check the customer Bedrock budget.
- See customer IAM users, access keys, and Bedrock bearer credentials.
- Review recent Bedrock activity from CloudTrail.
- Aggregate token counts from Bedrock invocation logs when a CloudWatch Logs
  destination is configured.
- Show scoped Cost Explorer totals when a Billing View is configured.
- Create a new Bedrock credential with customer and key-level tags.
- Smoke-test the operator key end to end.
- Disable a customer key without deleting the IAM user.

## Install

Copy the skill into your Codex skills folder:

```bash
cp -R bedrock-customer-usage ~/.codex/skills/
```

Restart Codex if it does not appear right away.

## Set Up Once

Create a local config file for the customer scope:

```bash
mkdir -p ~/.config/bedrock-customer-usage
cp bedrock-customer-usage/config.example.env ~/.config/bedrock-customer-usage/config.env
```

Edit the copied file once with your account, budget, IAM path, and optional
Billing View ARN. The scripts auto-load this file.

Put the operator AWS credential in a separate private env file:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=ap-southeast-1
export AWS_DEFAULT_REGION=ap-southeast-1
```

Do not commit real credentials.

## Operator Permissions

The operator key should be scoped to the customer IAM path. For the default
create-key flow it needs:

```text
iam:CreateUser
iam:TagUser
iam:PutUserPolicy
iam:CreateAccessKey
iam:UpdateAccessKey
iam:DeleteAccessKey
iam:GetUser
iam:ListUsers
iam:ListAccessKeys
iam:ListUserTags
```

For usage checks, add the read-only permissions you plan to expose:

```text
budgets:DescribeBudget
budgets:DescribeNotificationsForBudget
cloudtrail:LookupEvents
cloudwatch:ListMetrics
cloudwatch:GetMetricData
bedrock:GetModelInvocationLoggingConfiguration
```

For optional token usage from Bedrock model invocation logs, add read-only access
to the specific CloudWatch log group:

```text
logs:StartQuery
logs:GetQueryResults
```

If you use Cost Explorer, prefer a customer-scoped Billing View and grant Cost
Explorer access only through that view.

## Check Usage

Point the script at the operator credential file:

```bash
export BEDROCK_USAGE_OPERATOR_CREDENTIALS=/secure/path/operator.env
```

Run a 24-hour usage check:

```bash
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh --hours 24
```

Run a longer check:

```bash
bedrock-customer-usage/scripts/check_bedrock_customer_usage.sh --hours 168 --recent 20
```

The output includes:

- Budget actual spend and alert state.
- Active customer keys.
- Scoped monthly Cost Explorer total, if configured.
- Recent Bedrock calls grouped by key and model.
- Basic CloudWatch metric and Bedrock logging visibility checks.
- Aggregate token usage from invocation logs, if `BEDROCK_USAGE_INVOCATION_LOG_GROUP`
  is configured.

To enable token usage aggregation, set the CloudWatch Logs destination:

```bash
export BEDROCK_USAGE_INVOCATION_LOG_GROUP=/aws/bedrock/model-invocations
```

The script uses CloudWatch Logs Insights and prints only aggregate calls, model
ids, principal names, request metadata, and token counts. It does not print raw
prompts or responses.

## Create a Customer Key

For daily use, you only need the operator credential and the customer key name.

```bash
export BEDROCK_KEY_OPERATOR_CREDENTIALS=/secure/path/operator.env
```

Or export the two AWS credential values directly:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
```

Create one key:

```bash
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh \
  --customer example-customer \
  --key-alias prod \
  --output-dir ./secrets
```

For a temporary test key, the script can generate a customer tag:

```bash
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh \
  --auto-customer \
  --key-alias test \
  --output-dir ./secrets
```

Use `--auto-customer` only for temporary keys. Production keys should use a
stable `--customer` value so Cost Explorer groups are readable.

The script creates one IAM user and one credential, saves it to a local `0600`
env file, and prints only a masked access key id or masked bearer token.

By default, the script creates AWS access key credentials:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=ap-southeast-1
export AWS_DEFAULT_REGION=ap-southeast-1
```

To create a Bedrock bearer API key instead, use:

```bash
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh \
  --customer example-customer \
  --key-alias prod \
  --credential-type bearer \
  --bearer-token-days 90 \
  --output-dir ./secrets
```

That writes:

```bash
export AWS_BEARER_TOKEN_BEDROCK=...
export AWS_REGION=ap-southeast-1
export AWS_DEFAULT_REGION=ap-southeast-1
```

Bearer token verification may take a few seconds after creation while IAM
propagates the new service-specific credential.

By default, the script adds a small inline IAM policy that allows Bedrock model
list/invoke/converse actions only. Bearer credentials also get
`bedrock:CallWithBearerToken`. If your account requires managed policies or a
permissions boundary, set these optional values in the config file:

```bash
export BEDROCK_KEY_RUNTIME_POLICY_ARN=arn:aws:iam::123456789012:policy/BedrockCustomerRuntime
export BEDROCK_KEY_BOUNDARY_POLICY_ARN=arn:aws:iam::123456789012:policy/BedrockCustomerBoundary
```

Run an operator smoke test:

```bash
bedrock-customer-usage/scripts/smoke_bedrock_customer_operator.sh
```

The smoke test creates a temporary customer user/credential, verifies Bedrock
access, disables and deletes the temporary credential, and then tries to clean up
the temporary IAM user. To smoke-test bearer tokens:

```bash
bedrock-customer-usage/scripts/smoke_bedrock_customer_operator.sh \
  --credential-type bearer \
  --bearer-token-days 1
```

Disable a customer key:

```bash
bedrock-customer-usage/scripts/disable_bedrock_customer_key.sh \
  --access-key-id AKIA...
```

Or disable a Bedrock bearer API key:

```bash
bedrock-customer-usage/scripts/disable_bedrock_customer_key.sh \
  --service-credential-id ACCA...
```

The disable script only acts on keys under the configured customer IAM path.

## Cost Attribution

For clean cost reporting, keep this rule:

```text
one access key = one IAM user
```

For bearer API keys, use the same attribution rule:

```text
one Bedrock bearer credential = one IAM user
```

Each created user is tagged with:

- `customer`: customer-level reporting
- `usageOwner`: key-level reporting
- `keyAlias`: human-readable key label

AWS billing data is delayed. New tags may take time to appear in Cost Explorer
before per-customer or per-key cost groups show up.

CloudTrail can show activity by access key. For Bedrock bearer credentials, the
script looks up CloudTrail activity by IAM user name and filters for Bedrock
events. Exact token-level or prompt-level usage by key requires Bedrock
invocation logging and read access to the chosen log destination.

## Safety

Use a narrow operator key. It should manage only the intended customer IAM path
and should query Cost Explorer only through a customer-scoped Billing View.

Use AWS access keys by default for SDK, CLI, and server calls. Use Bedrock bearer
API keys only when the caller specifically needs `AWS_BEARER_TOKEN_BEDROCK`.
Bearer API keys are IAM service-specific credentials for
`bedrock.amazonaws.com`; keep them short-lived and scoped to the customer IAM
path.
