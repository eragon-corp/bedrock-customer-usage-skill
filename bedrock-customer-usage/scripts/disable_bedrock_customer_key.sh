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

ACCESS_KEY_ID=""
USER_NAME=""

usage() {
  cat <<EOF
Usage: $0 --access-key-id KEY_ID [--user-name USER_NAME]

Disables one access key only if it belongs to an IAM user under the configured
customer path. This uses iam:UpdateAccessKey and does not delete the key or user.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --access-key-id)
      ACCESS_KEY_ID="$2"
      shift 2
      ;;
    --user-name)
      USER_NAME="$2"
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

if [[ -z "$ACCESS_KEY_ID" ]]; then
  echo "--access-key-id is required" >&2
  usage >&2
  exit 2
fi

CUSTOMER_PATH="${BEDROCK_KEY_CUSTOMER_PATH:-${BEDROCK_USAGE_CUSTOMER_PATH:-}}"
if [[ -z "$CUSTOMER_PATH" ]]; then
  echo "Set BEDROCK_KEY_CUSTOMER_PATH or BEDROCK_USAGE_CUSTOMER_PATH" >&2
  exit 2
fi
OPERATOR_CRED="${BEDROCK_KEY_OPERATOR_CREDENTIALS:-${BEDROCK_USAGE_OPERATOR_CREDENTIALS:-}}"

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 127
  fi
}

require_bin aws
require_bin jq

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
      echo "operator credential file does not exist: $OPERATOR_CRED" >&2
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

resolve_user_for_key() {
  local candidate_user key_json

  if [[ -n "$USER_NAME" ]]; then
    user_json=$(aws_operator iam get-user --user-name "$USER_NAME" --output json)
    user_path=$(printf '%s' "$user_json" | jq -r '.User.Path')
    if [[ "$user_path" != "$CUSTOMER_PATH"* ]]; then
      echo "refusing to disable key: user path is $user_path, expected prefix $CUSTOMER_PATH" >&2
      exit 3
    fi
    key_json=$(aws_operator iam list-access-keys --user-name "$USER_NAME" --output json)
    if printf '%s' "$key_json" | jq -e --arg key "$ACCESS_KEY_ID" '.AccessKeyMetadata[]? | select(.AccessKeyId == $key)' >/dev/null; then
      printf '%s' "$USER_NAME"
      return 0
    fi
    echo "key $(mask_key "$ACCESS_KEY_ID") was not found on user $USER_NAME" >&2
    exit 4
  fi

  users_json=$(aws_operator iam list-users --path-prefix "$CUSTOMER_PATH" --output json)
  while IFS= read -r candidate_user; do
    key_json=$(aws_operator iam list-access-keys --user-name "$candidate_user" --output json)
    if printf '%s' "$key_json" | jq -e --arg key "$ACCESS_KEY_ID" '.AccessKeyMetadata[]? | select(.AccessKeyId == $key)' >/dev/null; then
      printf '%s' "$candidate_user"
      return 0
    fi
  done < <(printf '%s' "$users_json" | jq -r '.Users[]?.UserName')

  echo "key $(mask_key "$ACCESS_KEY_ID") was not found under path $CUSTOMER_PATH" >&2
  exit 4
}

TARGET_USER=$(resolve_user_for_key)
echo "disabling_key=$(mask_key "$ACCESS_KEY_ID") user=$TARGET_USER path=$CUSTOMER_PATH"
aws_operator iam update-access-key \
  --user-name "$TARGET_USER" \
  --access-key-id "$ACCESS_KEY_ID" \
  --status Inactive
echo "done"
