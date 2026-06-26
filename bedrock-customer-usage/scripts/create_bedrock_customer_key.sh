#!/usr/bin/env bash
set -euo pipefail

CUSTOMER=""
KEY_ALIAS="default"
USER_NAME=""
USAGE_OWNER=""
OUTPUT_DIR="./secrets"
VERIFY=1
CREATED_BY="${BEDROCK_KEY_CREATED_BY:-bedrock-customer-key-manager}"

CUSTOMER_PATH="${BEDROCK_KEY_CUSTOMER_PATH:?Set BEDROCK_KEY_CUSTOMER_PATH}"
OWNER="${BEDROCK_KEY_OWNER:?Set BEDROCK_KEY_OWNER}"
PURPOSE="${BEDROCK_KEY_PURPOSE:?Set BEDROCK_KEY_PURPOSE}"
REGION="${BEDROCK_KEY_REGION:-ap-southeast-1}"
RUNTIME_POLICY_ARN="${BEDROCK_KEY_RUNTIME_POLICY_ARN:?Set BEDROCK_KEY_RUNTIME_POLICY_ARN}"
BOUNDARY_POLICY_ARN="${BEDROCK_KEY_BOUNDARY_POLICY_ARN:?Set BEDROCK_KEY_BOUNDARY_POLICY_ARN}"
OPERATOR_CRED="${BEDROCK_KEY_OPERATOR_CREDENTIALS:-}"

usage() {
  cat <<EOF
Usage: $0 --customer NAME [--key-alias NAME] [--usage-owner VALUE] [--user-name NAME] [--output-dir DIR] [--no-verify]

Creates one IAM user and one Bedrock access key, with tags for future customer
and per-key cost attribution.

Required environment:
  BEDROCK_KEY_CUSTOMER_PATH
  BEDROCK_KEY_OWNER
  BEDROCK_KEY_PURPOSE
  BEDROCK_KEY_RUNTIME_POLICY_ARN
  BEDROCK_KEY_BOUNDARY_POLICY_ARN

Optional environment:
  BEDROCK_KEY_OPERATOR_CREDENTIALS
  BEDROCK_KEY_REGION
  BEDROCK_KEY_CREATED_BY
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --customer)
      CUSTOMER="$2"
      shift 2
      ;;
    --key-alias)
      KEY_ALIAS="$2"
      shift 2
      ;;
    --usage-owner)
      USAGE_OWNER="$2"
      shift 2
      ;;
    --user-name)
      USER_NAME="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --no-verify)
      VERIFY=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$CUSTOMER" ]]; then
  echo "--customer is required" >&2
  usage >&2
  exit 2
fi

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 127
  fi
}

require_bin aws
require_bin jq
require_bin python3

slugify() {
  python3 - "$1" <<'PY'
import re
import sys

s = sys.argv[1].strip().lower()
s = re.sub(r"[^a-z0-9-]+", "-", s)
s = re.sub(r"-+", "-", s).strip("-")
print(s or "item")
PY
}

mask_key() {
  local key="$1"
  if [[ ${#key} -le 12 ]]; then
    printf '%s' "$key"
  else
    printf '%s...%s' "${key:0:8}" "${key: -4}"
  fi
}

aws_operator() {
  if [[ -n "$OPERATOR_CRED" ]]; then
    if [[ ! -f "$OPERATOR_CRED" ]]; then
      echo "BEDROCK_KEY_OPERATOR_CREDENTIALS does not exist: $OPERATOR_CRED" >&2
      exit 2
    fi
    (
      set -a
      # shellcheck disable=SC1090
      source "$OPERATOR_CRED"
      set +a
      aws "$@"
    )
  else
    aws "$@"
  fi
}

CUSTOMER_SLUG=$(slugify "$CUSTOMER")
ALIAS_SLUG=$(slugify "$KEY_ALIAS")
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [[ -z "$USAGE_OWNER" ]]; then
  USAGE_OWNER="${CUSTOMER_SLUG}-${ALIAS_SLUG}-${TIMESTAMP}"
fi

if [[ -z "$USER_NAME" ]]; then
  USER_NAME=$(python3 - "$CUSTOMER_SLUG" "$ALIAS_SLUG" "$TIMESTAMP" <<'PY'
import sys

customer, alias, ts = sys.argv[1:4]
prefix = "bedrock"
max_len = 64
fixed = len(prefix) + 1 + 1 + len(ts)
remaining = max_len - fixed
customer_len = min(len(customer), max(8, remaining // 2))
alias_len = max(4, remaining - customer_len)
name = f"{prefix}-{customer[:customer_len]}-{alias[:alias_len]}-{ts}"
print(name[:max_len].strip("-"))
PY
)
fi

mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"
OUT_FILE="${OUTPUT_DIR%/}/${USER_NAME}.env"
TMP_KEY_JSON=$(mktemp)
trap 'rm -f "$TMP_KEY_JSON"' EXIT

echo "creating_user=$USER_NAME"
echo "path=$CUSTOMER_PATH"
echo "customer=$CUSTOMER_SLUG key_alias=$ALIAS_SLUG usage_owner=$USAGE_OWNER"

aws_operator iam create-user \
  --user-name "$USER_NAME" \
  --path "$CUSTOMER_PATH" \
  --permissions-boundary "$BOUNDARY_POLICY_ARN" \
  --tags \
    Key=Purpose,Value="$PURPOSE" \
    Key=owner,Value="$OWNER" \
    Key=customer,Value="$CUSTOMER_SLUG" \
    Key=usageOwner,Value="$USAGE_OWNER" \
    Key=keyAlias,Value="$ALIAS_SLUG" \
    Key=region,Value="$REGION" \
    Key=budgetScope,Value=bedrock \
    Key=createdBy,Value="$CREATED_BY" \
    Key=createdAt,Value="$CREATED_AT" \
  >/dev/null

aws_operator iam attach-user-policy \
  --user-name "$USER_NAME" \
  --policy-arn "$RUNTIME_POLICY_ARN"

aws_operator iam create-access-key --user-name "$USER_NAME" > "$TMP_KEY_JSON"
ACCESS_KEY_ID=$(jq -r '.AccessKey.AccessKeyId' "$TMP_KEY_JSON")

umask 077
jq -r --arg region "$REGION" '
  "export AWS_ACCESS_KEY_ID=" + .AccessKey.AccessKeyId,
  "export AWS_SECRET_ACCESS_KEY=" + .AccessKey.SecretAccessKey,
  "export AWS_REGION=" + $region,
  "export AWS_DEFAULT_REGION=" + $region
' "$TMP_KEY_JSON" > "$OUT_FILE"
chmod 600 "$OUT_FILE"

echo "access_key=$(mask_key "$ACCESS_KEY_ID")"
echo "credentials_file=$OUT_FILE"

if [[ "$VERIFY" -eq 1 ]]; then
  echo "verify=started"
  (
    set -a
    # shellcheck disable=SC1090
    source "$OUT_FILE"
    set +a
    model_count=""
    for attempt in $(seq 1 20); do
      set +e
      model_count=$(aws bedrock list-foundation-models --region "$REGION" --query 'length(modelSummaries)' --output text 2>/tmp/bedrock_key_verify_error.txt)
      status=$?
      set -e
      if [[ "$status" -eq 0 ]]; then
        break
      fi
      if [[ "$attempt" -eq 20 ]]; then
        echo "bedrock_verify=failed"
        sed 's/^/  /' /tmp/bedrock_key_verify_error.txt
        exit "$status"
      fi
      sleep 3
    done
    echo "bedrock_model_count=$model_count"
    set +e
    s3_out=$(aws s3 ls 2>&1)
    s3_status=$?
    set -e
    if [[ "$s3_status" -eq 0 ]]; then
      echo "s3=unexpected_allowed"
      exit 3
    else
      echo "s3=denied_ok"
    fi
  )
fi

echo "done"
