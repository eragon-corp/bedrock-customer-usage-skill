#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="${BEDROCK_CUSTOMER_USAGE_CONFIG:-}"

if [[ -z "$CONFIG_FILE" ]]; then
  for candidate in \
    "$PWD/bedrock-customer-usage.env" \
    "$HOME/.config/bedrock-customer-usage/config.env" \
    "$SCRIPT_DIR/../config.env"; do
    if [[ -f "$candidate" ]]; then
      CONFIG_FILE="$candidate"
      break
    fi
  done
fi

if [[ -n "$CONFIG_FILE" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "BEDROCK_CUSTOMER_USAGE_CONFIG does not exist: $CONFIG_FILE" >&2
    exit 2
  fi
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
fi

CUSTOMER="smoke"
KEY_ALIAS="operator"
VERIFY_MODEL_ID="${BEDROCK_KEY_VERIFY_MODEL_ID:-anthropic.claude-3-haiku-20240307-v1:0}"
CREDENTIAL_TYPE="${BEDROCK_KEY_CREDENTIAL_TYPE:-access-key}"
BEARER_TOKEN_DAYS="${BEDROCK_KEY_BEARER_TOKEN_DAYS:-90}"

usage() {
  cat <<EOF
Usage: $0 [--customer NAME] [--key-alias NAME] [--credential-type access-key|bearer] [--bearer-token-days DAYS] [--verify-model MODEL_ID]

Creates a temporary customer IAM user and credential under the configured path,
verifies Bedrock access through the newly-created credential, then disables and
deletes that temporary credential.

The temporary IAM user cleanup is best-effort. If the operator key does not have
delete-user-policy/delete-user permissions, the script prints the exact admin
cleanup commands.
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
    --credential-type)
      CREDENTIAL_TYPE="$2"
      shift 2
      ;;
    --access-key)
      CREDENTIAL_TYPE="access-key"
      shift
      ;;
    --bearer-token)
      CREDENTIAL_TYPE="bearer"
      shift
      ;;
    --bearer-token-days|--credential-age-days)
      BEARER_TOKEN_DAYS="$2"
      shift 2
      ;;
    --verify-model)
      VERIFY_MODEL_ID="$2"
      shift 2
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

case "$CREDENTIAL_TYPE" in
  access-key|bearer)
    ;;
  *)
    echo "--credential-type must be access-key or bearer" >&2
    usage >&2
    exit 2
    ;;
esac

OPERATOR_CRED="${BEDROCK_KEY_OPERATOR_CREDENTIALS:-}"
INLINE_POLICY_NAME="${BEDROCK_KEY_INLINE_POLICY_NAME:-BedrockCustomerRuntime}"
RUNTIME_POLICY_ARN="${BEDROCK_KEY_RUNTIME_POLICY_ARN:-}"
TMP_DIR=$(mktemp -d)
USER_NAME="bedrock-smoke-$(date -u +%Y%m%dT%H%M%SZ)"
CREATED_KEY_ID=""
CREATED_SERVICE_CREDENTIAL_ID=""
USER_EXISTS=0

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 127
  fi
}

require_bin aws
require_bin jq

aws_operator() {
  if [[ -n "$OPERATOR_CRED" ]]; then
    if [[ ! -f "$OPERATOR_CRED" ]]; then
      echo "BEDROCK_KEY_OPERATOR_CREDENTIALS does not exist: $OPERATOR_CRED" >&2
      exit 2
    fi
    (
      export AWS_PAGER=""
      set -a
      # shellcheck disable=SC1090
      source "$OPERATOR_CRED"
      set +a
      aws "$@"
    )
  else
    AWS_PAGER="" aws "$@"
  fi
}

cleanup() {
  local status=$?
  local discovered_keys discovered_credentials

  if [[ -n "$CREATED_KEY_ID" ]]; then
    echo "cleanup_key=started"
    aws_operator iam update-access-key \
      --user-name "$USER_NAME" \
      --access-key-id "$CREATED_KEY_ID" \
      --status Inactive >/dev/null 2>&1 || true
    aws_operator iam delete-access-key \
      --user-name "$USER_NAME" \
      --access-key-id "$CREATED_KEY_ID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$CREATED_SERVICE_CREDENTIAL_ID" ]]; then
    echo "cleanup_service_credential=started"
    aws_operator iam update-service-specific-credential \
      --user-name "$USER_NAME" \
      --service-specific-credential-id "$CREATED_SERVICE_CREDENTIAL_ID" \
      --status Inactive >/dev/null 2>&1 || true
    aws_operator iam delete-service-specific-credential \
      --user-name "$USER_NAME" \
      --service-specific-credential-id "$CREATED_SERVICE_CREDENTIAL_ID" >/dev/null 2>&1 || true
  fi

  if [[ "$USER_EXISTS" -eq 1 ]] || aws_operator iam get-user --user-name "$USER_NAME" >/dev/null 2>&1; then
    if [[ -z "$CREATED_KEY_ID" ]]; then
      discovered_keys=$(aws_operator iam list-access-keys --user-name "$USER_NAME" --output json 2>/dev/null || printf '{}')
      while IFS= read -r key_id; do
        [[ -n "$key_id" ]] || continue
        echo "cleanup_discovered_key=started"
        aws_operator iam update-access-key \
          --user-name "$USER_NAME" \
          --access-key-id "$key_id" \
          --status Inactive >/dev/null 2>&1 || true
        aws_operator iam delete-access-key \
          --user-name "$USER_NAME" \
          --access-key-id "$key_id" >/dev/null 2>&1 || true
      done < <(printf '%s' "$discovered_keys" | jq -r '.AccessKeyMetadata[]?.AccessKeyId')
    fi

    if [[ -z "$CREATED_SERVICE_CREDENTIAL_ID" ]]; then
      discovered_credentials=$(aws_operator iam list-service-specific-credentials \
        --user-name "$USER_NAME" \
        --service-name bedrock.amazonaws.com \
        --output json 2>/dev/null || printf '{}')
      while IFS= read -r credential_id; do
        [[ -n "$credential_id" ]] || continue
        echo "cleanup_discovered_service_credential=started"
        aws_operator iam update-service-specific-credential \
          --user-name "$USER_NAME" \
          --service-specific-credential-id "$credential_id" \
          --status Inactive >/dev/null 2>&1 || true
        aws_operator iam delete-service-specific-credential \
          --user-name "$USER_NAME" \
          --service-specific-credential-id "$credential_id" >/dev/null 2>&1 || true
      done < <(printf '%s' "$discovered_credentials" | jq -r '.ServiceSpecificCredentials[]?.ServiceSpecificCredentialId')
    fi

    if [[ -n "$RUNTIME_POLICY_ARN" ]]; then
      aws_operator iam detach-user-policy \
        --user-name "$USER_NAME" \
        --policy-arn "$RUNTIME_POLICY_ARN" >/dev/null 2>&1 || true
    else
      aws_operator iam delete-user-policy \
        --user-name "$USER_NAME" \
        --policy-name "$INLINE_POLICY_NAME" >/dev/null 2>&1 || true
    fi

    if aws_operator iam delete-user --user-name "$USER_NAME" >/dev/null 2>&1; then
      echo "cleanup_user=deleted"
    else
      echo "cleanup_user=manual_required user=$USER_NAME"
      if [[ -n "$RUNTIME_POLICY_ARN" ]]; then
        echo "admin_cleanup_detach=aws iam detach-user-policy --user-name $USER_NAME --policy-arn $RUNTIME_POLICY_ARN"
      else
        echo "admin_cleanup_policy=aws iam delete-user-policy --user-name $USER_NAME --policy-name $INLINE_POLICY_NAME"
      fi
      echo "admin_cleanup_user=aws iam delete-user --user-name $USER_NAME"
    fi
  fi

  rm -rf "$TMP_DIR"
  exit "$status"
}
trap cleanup EXIT

echo "smoke_user=$USER_NAME"
echo "credential_type=$CREDENTIAL_TYPE"
"$SCRIPT_DIR/create_bedrock_customer_key.sh" \
  --customer "$CUSTOMER" \
  --key-alias "$KEY_ALIAS" \
  --credential-type "$CREDENTIAL_TYPE" \
  --bearer-token-days "$BEARER_TOKEN_DAYS" \
  --user-name "$USER_NAME" \
  --output-dir "$TMP_DIR" \
  --verify-model "$VERIFY_MODEL_ID"
USER_EXISTS=1

cred_file="$TMP_DIR/$USER_NAME.env"
if [[ ! -f "$cred_file" ]]; then
  echo "created credential file was not found: $cred_file" >&2
  exit 5
fi

if [[ "$CREDENTIAL_TYPE" == "bearer" ]]; then
  CREATED_SERVICE_CREDENTIAL_ID=$(awk -F= '/^export BEDROCK_SERVICE_SPECIFIC_CREDENTIAL_ID=/{print $2}' "$cred_file" | head -n1)
  if [[ -z "$CREATED_SERVICE_CREDENTIAL_ID" ]]; then
    echo "created service credential id was not found in credential file" >&2
    exit 5
  fi
else
  CREATED_KEY_ID=$(awk -F= '/^export AWS_ACCESS_KEY_ID=/{print $2}' "$cred_file" | head -n1)
  if [[ -z "$CREATED_KEY_ID" ]]; then
    echo "created access key id was not found in credential file" >&2
    exit 5
  fi
fi

echo "smoke_result=ok"
