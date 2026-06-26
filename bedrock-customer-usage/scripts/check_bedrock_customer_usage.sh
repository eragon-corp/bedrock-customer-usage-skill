#!/usr/bin/env bash
set -euo pipefail

ACCOUNT_ID="${BEDROCK_USAGE_AWS_ACCOUNT_ID:?Set BEDROCK_USAGE_AWS_ACCOUNT_ID}"
REGION="${BEDROCK_USAGE_AWS_REGION:-ap-southeast-1}"
BUDGET_NAME="${BEDROCK_USAGE_BUDGET_NAME:?Set BEDROCK_USAGE_BUDGET_NAME}"
CUSTOMER_PATH="${BEDROCK_USAGE_CUSTOMER_PATH:?Set BEDROCK_USAGE_CUSTOMER_PATH}"
OPERATOR_CRED="${BEDROCK_USAGE_OPERATOR_CREDENTIALS:-}"
HOURS=24
MAX_PAGES=10
RECENT_LIMIT=10

usage() {
  cat <<EOF
Usage: $0 [--hours N] [--max-pages N] [--recent N]

Checks customer-scoped Bedrock budget cost, customer key status, CloudTrail Bedrock usage,
CloudWatch metric visibility, and Bedrock invocation logging config.

Required:
  BEDROCK_USAGE_AWS_ACCOUNT_ID
  BEDROCK_USAGE_BUDGET_NAME
  BEDROCK_USAGE_CUSTOMER_PATH

Optional:
  BEDROCK_USAGE_AWS_REGION
  BEDROCK_USAGE_OPERATOR_CREDENTIALS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours)
      HOURS="$2"
      shift 2
      ;;
    --max-pages)
      MAX_PAGES="$2"
      shift 2
      ;;
    --recent)
      RECENT_LIMIT="$2"
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

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 127
  fi
}

require_bin aws
require_bin jq
require_bin python3

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
      echo "BEDROCK_USAGE_OPERATOR_CREDENTIALS does not exist: $OPERATOR_CRED" >&2
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

time_json=$(python3 - "$HOURS" <<'PY'
import datetime as dt
import json
import sys

hours = int(sys.argv[1])
end = dt.datetime.now(dt.timezone.utc)
start = end - dt.timedelta(hours=hours)
print(json.dumps({
    "start": start.isoformat(timespec="seconds").replace("+00:00", "Z"),
    "end": end.isoformat(timespec="seconds").replace("+00:00", "Z"),
}))
PY
)
START_TIME=$(printf '%s' "$time_json" | jq -r '.start')
END_TIME=$(printf '%s' "$time_json" | jq -r '.end')

echo "== Bedrock customer usage =="
echo "account=$ACCOUNT_ID region=$REGION window=${HOURS}h start=$START_TIME end=$END_TIME"
echo

echo "== Budget cost =="
if budget_json=$(aws_operator budgets describe-budget --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME" --output json 2>/tmp/bedrock_usage_budget_error.txt); then
  printf '%s' "$budget_json" | jq -r '
    .Budget as $b
    | [
      "budget=\($b.BudgetName)",
      "limit=\($b.BudgetLimit.Amount) \($b.BudgetLimit.Unit) / \($b.TimeUnit)",
      "actual=\($b.CalculatedSpend.ActualSpend.Amount // "Unavailable") \($b.CalculatedSpend.ActualSpend.Unit // "")",
      "tag_filter=\(($b.CostFilters.TagKeyValue // []) | join(","))",
      "service_filters_count=\(($b.CostFilters.Service // []) | length)"
    ]
    + (
      if $b.CalculatedSpend.ForecastedSpend.Amount then
        ["forecast=\($b.CalculatedSpend.ForecastedSpend.Amount) \($b.CalculatedSpend.ForecastedSpend.Unit)"]
      else
        []
      end
    )
    | .[]
  '
else
  echo "budget=unavailable"
  sed 's/^/  /' /tmp/bedrock_usage_budget_error.txt
fi

if notifications_json=$(aws_operator budgets describe-notifications-for-budget --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME" --output json 2>/dev/null); then
  echo "notifications="
  printf '%s' "$notifications_json" | jq -r '.Notifications[]? | "  \(.NotificationType) \(.ComparisonOperator) \(.Threshold)% state=\(.NotificationState)"'
fi
echo

echo "== Customer keys =="
users_json=$(aws_operator iam list-users --path-prefix "$CUSTOMER_PATH" --output json)
user_count=$(printf '%s' "$users_json" | jq '(.Users // []) | length')
echo "users=$user_count path=$CUSTOMER_PATH"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
keys_file="$tmp_dir/keys.tsv"
: > "$keys_file"

printf '%s' "$users_json" | jq -r '.Users[]?.UserName' | while IFS= read -r user_name; do
  tags_json=$(aws_operator iam list-user-tags --user-name "$user_name" --output json)
  purpose=$(printf '%s' "$tags_json" | jq -r '.Tags[]? | select(.Key=="Purpose") | .Value' | head -n1)
  owner=$(printf '%s' "$tags_json" | jq -r '.Tags[]? | select(.Key=="owner") | .Value' | head -n1)
  customer=$(printf '%s' "$tags_json" | jq -r '.Tags[]? | select(.Key=="customer") | .Value' | head -n1)
  keys_json=$(aws_operator iam list-access-keys --user-name "$user_name" --output json)
  printf '%s' "$keys_json" | jq -r --arg user "$user_name" --arg purpose "$purpose" --arg owner "$owner" --arg customer "$customer" '
    .AccessKeyMetadata[]?
    | [$user, .AccessKeyId, .Status, .CreateDate, $purpose, $owner, $customer]
    | @tsv
  ' >> "$keys_file"
done

if [[ -s "$keys_file" ]]; then
  while IFS=$'\t' read -r user_name key_id status create_date purpose owner customer; do
    echo "user=$user_name key=$(mask_key "$key_id") status=$status created=$create_date Purpose=${purpose:-} owner=${owner:-} customer=${customer:-}"
  done < "$keys_file"
else
  echo "no access keys found"
fi
echo

echo "== CloudTrail Bedrock usage =="
events_file="$tmp_dir/events.jsonl"
: > "$events_file"

while IFS=$'\t' read -r user_name key_id status create_date purpose owner customer; do
  [[ "$status" == "Active" ]] || continue
  next_token=""
  page=0
  while [[ $page -lt $MAX_PAGES ]]; do
    args=(cloudtrail lookup-events
      --region "$REGION"
      --lookup-attributes "AttributeKey=AccessKeyId,AttributeValue=$key_id"
      --start-time "$START_TIME"
      --end-time "$END_TIME"
      --max-results 50
      --output json)
    if [[ -n "$next_token" ]]; then
      args+=(--next-token "$next_token")
    fi
    page_json=$(aws_operator "${args[@]}")
    printf '%s' "$page_json" | jq -c --arg user "$user_name" --arg key "$key_id" '
      .Events[]?
      | (.CloudTrailEvent | fromjson?)
      | select(.eventSource == "bedrock.amazonaws.com")
      | {
          userName: $user,
          accessKeyId: $key,
          eventTime,
          eventName,
          region: .awsRegion,
          modelId: (
            .requestParameters.modelId
            // .requestParameters.modelIdentifier
            // .requestParameters.foundationModelIdentifier
            // null
          ),
          errorCode: (.errorCode // null)
        }
    ' >> "$events_file"
    next_token=$(printf '%s' "$page_json" | jq -r '.NextToken // empty')
    [[ -n "$next_token" ]] || break
    page=$((page + 1))
    sleep 0.6
  done
done < "$keys_file"

event_count=$(wc -l < "$events_file" | tr -d ' ')
echo "bedrock_events=$event_count"
if [[ "$event_count" != "0" ]]; then
  echo "by_key="
  jq -sr '
    group_by(.accessKeyId)
    | .[]
    | {
        key: (.[0].accessKeyId[0:8] + "..." + .[0].accessKeyId[-4:]),
        user: .[0].userName,
        events: length,
        errors: map(select(.errorCode != null)) | length
      }
    | "  key=\(.key) user=\(.user) events=\(.events) errors=\(.errors)"
  ' "$events_file"
  echo "by_model="
  jq -sr '
    map(select(.modelId != null))
    | group_by(.modelId)
    | .[]
    | {modelId: .[0].modelId, events: length}
    | "  model=\(.modelId) events=\(.events)"
  ' "$events_file"
  echo "recent="
  jq -sr --argjson n "$RECENT_LIMIT" '
    sort_by(.eventTime)
    | reverse
    | .[:$n]
    | .[]
    | "  \(.eventTime) \(.eventName) key=\(.accessKeyId[0:8])...\(.accessKeyId[-4:]) model=\(.modelId // "unknown") error=\(.errorCode // "none")"
  ' "$events_file"
fi
echo

echo "== CloudWatch and Bedrock logging diagnostics =="
if metrics_json=$(aws_operator cloudwatch list-metrics --region "$REGION" --namespace AWS/Bedrock --max-items 50 --output json 2>/tmp/bedrock_usage_metrics_error.txt); then
  metrics_count=$(printf '%s' "$metrics_json" | jq '(.Metrics // []) | length')
  echo "cloudwatch_list_metrics=ok count=$metrics_count"
  printf '%s' "$metrics_json" | jq -r '(.Metrics // [])[:10][] | "  metric=\(.MetricName) dimensions=\(.Dimensions | map(.Name + "=" + .Value) | join(","))"'
else
  echo "cloudwatch_list_metrics=unavailable"
  sed 's/^/  /' /tmp/bedrock_usage_metrics_error.txt
fi

if logging_json=$(aws_operator bedrock get-model-invocation-logging-configuration --region "$REGION" --output json 2>/tmp/bedrock_usage_logging_error.txt); then
  echo "bedrock_invocation_logging=ok"
  printf '%s' "$logging_json" | jq -c '.'
else
  echo "bedrock_invocation_logging=unavailable"
  sed 's/^/  /' /tmp/bedrock_usage_logging_error.txt
fi
