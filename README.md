# Bedrock Customer Usage Skill

Codex skill for checking customer-scoped AWS Bedrock budget and usage.

The skill reports:

- AWS Budget status for a configured Bedrock customer budget
- Optional scoped Cost Explorer totals through an AWS Billing View
- IAM users and access keys under a configured customer path
- Bedrock usage events from CloudTrail
- CloudWatch `AWS/Bedrock` metric visibility
- Bedrock model invocation logging configuration

It also includes an optional key creation workflow that creates one IAM user per
customer access key and tags it for future cost attribution.

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

Optional scoped Cost Explorer configuration:

```bash
export BEDROCK_USAGE_BILLING_VIEW_ARN=arn:aws:billing::123456789012:billingview/custom-...
export BEDROCK_USAGE_COST_SERVICE='Amazon Bedrock'
```

The Billing View should be filtered to the customer scope, for example by a
cost allocation tag such as `iamPrincipal/Purpose`. The script then queries
only that view and groups Bedrock cost by `iamPrincipal/customer` and
`iamPrincipal/usageOwner` when AWS has billing data for those tags.

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

## Create a Customer Bedrock Key

Configure the operator and policy inputs:

```bash
export BEDROCK_KEY_OPERATOR_CREDENTIALS=/secure/path/operator.env
export BEDROCK_KEY_CUSTOMER_PATH=/bedrock-customers/customer/
export BEDROCK_KEY_OWNER=customer-owner
export BEDROCK_KEY_PURPOSE=customer-purpose
export BEDROCK_KEY_REGION=ap-southeast-1
export BEDROCK_KEY_RUNTIME_POLICY_ARN=arn:aws:iam::123456789012:policy/BedrockCustomerRuntime
export BEDROCK_KEY_BOUNDARY_POLICY_ARN=arn:aws:iam::123456789012:policy/BedrockCustomerBoundary
```

Create a key:

```bash
bedrock-customer-usage/scripts/create_bedrock_customer_key.sh \
  --customer example-customer \
  --key-alias prod \
  --output-dir ./secrets
```

The script creates one IAM user and one access key, writes credentials to a
local `0600` env file, and prints only a masked access key id.

The IAM user is tagged for two-level cost attribution:

- Customer-level: `customer=<customer>`
- Key-level: `usageOwner=<customer>-<key_alias>-<timestamp>`

To make these tags available in AWS billing, activate cost allocation tags such
as `iamPrincipal/customer` and `iamPrincipal/usageOwner` after AWS discovers
them. Billing data is delayed and applies to future costs.

## Required AWS Permissions

The operator key should be scoped as narrowly as possible. At minimum it needs:

- `budgets:ViewBudget` for the customer budget ARN
- `iam:ListUsers` for discovery
- `iam:GetUser`, `iam:ListAccessKeys`, `iam:ListUserTags` for customer users
- `cloudtrail:LookupEvents` in the target region
- `cloudwatch:ListMetrics` in the target region
- `bedrock:GetModelInvocationLoggingConfiguration` in the target region
- Optional: `ce:GetCostAndUsage`, `ce:GetTags`, `ce:GetDimensionValues`, and
  `billing:GetBillingView` scoped to the configured Billing View ARN

Optional key-management flows may also need `iam:CreateAccessKey`, `iam:UpdateAccessKey`, and `iam:DeleteAccessKey` scoped to the customer IAM path.

For per-key future cost attribution, require these IAM user tags during key
creation:

- `customer`
- `usageOwner`
- `Purpose`
- `owner`
- `region`
- `budgetScope`

This skill does not require broad Cost Explorer access. If Cost Explorer is
enabled, grant it only on a customer-scoped Billing View ARN.
