# Bedrock Customer Usage Skill

Use this skill to manage customer-scoped AWS Bedrock access keys and check their
usage from Codex.

It helps you:

- Check the customer Bedrock budget.
- See customer IAM users and access keys.
- Review recent Bedrock activity from CloudTrail.
- Show scoped Cost Explorer totals when a Billing View is configured.
- Create a new Bedrock access key with customer and key-level tags.

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

Edit the copied file once with your account, budget, IAM path, policy ARNs, and
optional Billing View ARN. The scripts auto-load this file.

Put the operator AWS credential in a separate private env file:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=ap-southeast-1
export AWS_DEFAULT_REGION=ap-southeast-1
```

Do not commit real credentials.

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
- Basic CloudWatch and Bedrock logging visibility checks.

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

The script creates one IAM user and one access key, saves the credentials to a
local `0600` env file, and prints only a masked access key id.

## Cost Attribution

For clean cost reporting, keep this rule:

```text
one access key = one IAM user
```

Each created user is tagged with:

- `customer`: customer-level reporting
- `usageOwner`: key-level reporting

AWS billing data is delayed. New tags may take time to appear in Cost Explorer
before per-customer or per-key cost groups show up.

## Safety

Use a narrow operator key. It should manage only the intended customer IAM path
and should query Cost Explorer only through a customer-scoped Billing View.
