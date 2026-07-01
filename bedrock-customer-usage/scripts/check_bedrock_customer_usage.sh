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

HOURS=24
MAX_PAGES=10
RECENT_LIMIT=10
INVOCATION_LOG_GROUP="${BEDROCK_USAGE_INVOCATION_LOG_GROUP:-}"
INVOCATION_LOG_LIMIT="${BEDROCK_USAGE_INVOCATION_LOG_LIMIT:-100}"
INVOCATION_LOG_QUERY_TIMEOUT_SECONDS="${BEDROCK_USAGE_INVOCATION_LOG_QUERY_TIMEOUT_SECONDS:-60}"

usage() {
  cat <<EOF
Usage: $0 [--hours N] [--max-pages N] [--recent N] [--invocation-log-group NAME]

Checks customer-scoped Bedrock budget cost, customer key status, CloudTrail Bedrock usage,
CloudWatch metric visibility/data, Bedrock invocation logging config, and optional
invocation-log token usage.

Shared config:
  Auto-loads ./bedrock-customer-usage.env,
  ~/.config/bedrock-customer-usage/config.env, or bedrock-customer-usage/config.env.
  You can also set BEDROCK_CUSTOMER_USAGE_CONFIG.

Credentials:
  Set BEDROCK_USAGE_OPERATOR_CREDENTIALS, or export AWS_ACCESS_KEY_ID and
  AWS_SECRET_ACCESS_KEY directly.

Optional:
  BEDROCK_USAGE_COST_SERVICE
  BEDROCK_USAGE_INVOCATION_LOG_GROUP
  BEDROCK_USAGE_INVOCATION_LOG_LIMIT
  BEDROCK_USAGE_INVOCATION_LOG_QUERY_TIMEOUT_SECONDS
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
    --invocation-log-group)
      INVOCATION_LOG_GROUP="$2"
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

ACCOUNT_ID="${BEDROCK_USAGE_AWS_ACCOUNT_ID:?Set BEDROCK_USAGE_AWS_ACCOUNT_ID or BEDROCK_CUSTOMER_USAGE_CONFIG}"
REGION="${BEDROCK_USAGE_AWS_REGION:-ap-southeast-1}"
BUDGET_NAME="${BEDROCK_USAGE_BUDGET_NAME:?Set BEDROCK_USAGE_BUDGET_NAME or BEDROCK_CUSTOMER_USAGE_CONFIG}"
CUSTOMER_PATH="${BEDROCK_USAGE_CUSTOMER_PATH:?Set BEDROCK_USAGE_CUSTOMER_PATH or BEDROCK_CUSTOMER_USAGE_CONFIG}"
OPERATOR_CRED="${BEDROCK_USAGE_OPERATOR_CREDENTIALS:-}"
BILLING_VIEW_ARN="${BEDROCK_USAGE_BILLING_VIEW_ARN:-}"
COST_SERVICE="${BEDROCK_USAGE_COST_SERVICE:-Amazon Bedrock}"

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
      AWS_PAGER="" aws "$@"
    )
  else
    AWS_PAGER="" aws "$@"
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
    "start_epoch": int(start.timestamp()),
    "end_epoch": int(end.timestamp()),
}))
PY
)
START_TIME=$(printf '%s' "$time_json" | jq -r '.start')
END_TIME=$(printf '%s' "$time_json" | jq -r '.end')
START_EPOCH=$(printf '%s' "$time_json" | jq -r '.start_epoch')
END_EPOCH=$(printf '%s' "$time_json" | jq -r '.end_epoch')

cost_period_json=$(python3 <<'PY'
import datetime as dt
import json

today = dt.datetime.now(dt.timezone.utc).date()
start = today.replace(day=1)
end = today + dt.timedelta(days=1)
print(json.dumps({"start": start.isoformat(), "end": end.isoformat()}))
PY
)
COST_START=$(printf '%s' "$cost_period_json" | jq -r '.start')
COST_END=$(printf '%s' "$cost_period_json" | jq -r '.end')

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
service_credentials_file="$tmp_dir/service-credentials.tsv"
: > "$keys_file"
: > "$service_credentials_file"

printf '%s' "$users_json" | jq -r '.Users[]?.UserName' | while IFS= read -r user_name; do
  tags_json=$(aws_operator iam list-user-tags --user-name "$user_name" --output json)
  purpose=$(printf '%s' "$tags_json" | jq -r '.Tags[]? | select(.Key=="Purpose") | .Value' | head -n1)
  owner=$(printf '%s' "$tags_json" | jq -r '.Tags[]? | select(.Key=="owner") | .Value' | head -n1)
  customer=$(printf '%s' "$tags_json" | jq -r '.Tags[]? | select(.Key=="customer") | .Value' | head -n1)
  usage_owner=$(printf '%s' "$tags_json" | jq -r '.Tags[]? | select(.Key=="usageOwner") | .Value' | head -n1)
  key_alias=$(printf '%s' "$tags_json" | jq -r '.Tags[]? | select(.Key=="keyAlias") | .Value' | head -n1)
  keys_json=$(aws_operator iam list-access-keys --user-name "$user_name" --output json)
  printf '%s' "$keys_json" | jq -r --arg user "$user_name" --arg purpose "$purpose" --arg owner "$owner" --arg customer "$customer" --arg usage_owner "$usage_owner" --arg key_alias "$key_alias" '
    .AccessKeyMetadata[]?
    | [$user, .AccessKeyId, .Status, .CreateDate, $purpose, $owner, $customer, $usage_owner, $key_alias]
    | @tsv
  ' >> "$keys_file"
  service_credentials_json=$(aws_operator iam list-service-specific-credentials \
    --user-name "$user_name" \
    --service-name bedrock.amazonaws.com \
    --output json 2>/dev/null || printf '{}')
  printf '%s' "$service_credentials_json" | jq -r --arg user "$user_name" --arg purpose "$purpose" --arg owner "$owner" --arg customer "$customer" --arg usage_owner "$usage_owner" --arg key_alias "$key_alias" '
    .ServiceSpecificCredentials[]?
    | [$user, .ServiceSpecificCredentialId, .Status, .CreateDate, (.ServiceName // "bedrock.amazonaws.com"), $purpose, $owner, $customer, $usage_owner, $key_alias]
    | @tsv
  ' >> "$service_credentials_file"
done

if [[ -s "$keys_file" ]]; then
  echo "access_keys="
  while IFS=$'\t' read -r user_name key_id status create_date purpose owner customer usage_owner key_alias; do
    echo "  user=$user_name key=$(mask_key "$key_id") status=$status created=$create_date Purpose=${purpose:-} owner=${owner:-} customer=${customer:-} usageOwner=${usage_owner:-} keyAlias=${key_alias:-}"
  done < "$keys_file"
else
  echo "no access keys found"
fi
if [[ -s "$service_credentials_file" ]]; then
  echo "bedrock_bearer_credentials="
  while IFS=$'\t' read -r user_name credential_id status create_date service_name purpose owner customer usage_owner key_alias; do
    echo "  user=$user_name service_credential=$(mask_key "$credential_id") status=$status created=$create_date service=$service_name Purpose=${purpose:-} owner=${owner:-} customer=${customer:-} usageOwner=${usage_owner:-} keyAlias=${key_alias:-}"
  done < "$service_credentials_file"
else
  echo "no Bedrock bearer credentials found"
fi
echo

echo "== Scoped Cost Explorer =="
echo "period=$COST_START..$COST_END service=$COST_SERVICE"
if [[ -z "$BILLING_VIEW_ARN" ]]; then
  echo "billing_view=not_configured"
  echo "cost_detail=skipped"
else
  echo "billing_view=$BILLING_VIEW_ARN"
  if view_json=$(aws_operator billing get-billing-view --region us-east-1 --arn "$BILLING_VIEW_ARN" --output json 2>/tmp/bedrock_usage_billing_view_error.txt); then
    printf '%s' "$view_json" | jq -r '.billingView as $v | "billing_view_name=\($v.name) type=\($v.billingViewType) owner=\($v.ownerAccountId)"'
  else
    echo "billing_view_lookup=unavailable"
    sed 's/^/  /' /tmp/bedrock_usage_billing_view_error.txt
  fi

  cost_filter=$(jq -nc --arg service "$COST_SERVICE" '{"Dimensions":{"Key":"SERVICE","Values":[$service]}}')
  if total_cost_json=$(aws_operator ce get-cost-and-usage \
      --billing-view-arn "$BILLING_VIEW_ARN" \
      --time-period "Start=$COST_START,End=$COST_END" \
      --granularity MONTHLY \
      --metrics UnblendedCost UsageQuantity \
      --filter "$cost_filter" \
      --region us-east-1 \
      --output json 2>/tmp/bedrock_usage_ce_total_error.txt); then
    printf '%s' "$total_cost_json" | jq -r '
      .ResultsByTime[0] as $r
      | "total_unblended_cost=\($r.Total.UnblendedCost.Amount // "0") \($r.Total.UnblendedCost.Unit // "USD") estimated=\($r.Estimated)"
    '
  else
    echo "total_unblended_cost=unavailable"
    sed 's/^/  /' /tmp/bedrock_usage_ce_total_error.txt
  fi

  for tag_key in user:iamPrincipal/customer user:iamPrincipal/usageOwner; do
    label=${tag_key##*/}
    if grouped_cost_json=$(aws_operator ce get-cost-and-usage \
        --billing-view-arn "$BILLING_VIEW_ARN" \
        --time-period "Start=$COST_START,End=$COST_END" \
        --granularity MONTHLY \
        --metrics UnblendedCost UsageQuantity \
        --filter "$cost_filter" \
        --group-by "Type=TAG,Key=$tag_key" \
        --region us-east-1 \
        --output json 2>/tmp/bedrock_usage_ce_group_error.txt); then
      group_count=$(printf '%s' "$grouped_cost_json" | jq '[.ResultsByTime[].Groups[]?] | length')
      echo "by_${label}_groups=$group_count"
      if [[ "$group_count" != "0" ]]; then
        printf '%s' "$grouped_cost_json" | jq -r '
          .ResultsByTime[].Groups[]?
          | {
              tag: ((.Keys[0] // "") | split("$") | last),
              cost: (.Metrics.UnblendedCost.Amount // "0"),
              unit: (.Metrics.UnblendedCost.Unit // "USD"),
              usage: (.Metrics.UsageQuantity.Amount // "0")
            }
          | select(.tag != "")
          | "  tag=\(.tag) cost=\(.cost) \(.unit) usage_quantity=\(.usage)"
        '
      fi
    else
      echo "by_${label}=unavailable"
      sed 's/^/  /' /tmp/bedrock_usage_ce_group_error.txt
    fi
  done
fi
echo

echo "== CloudTrail Bedrock usage =="
events_file="$tmp_dir/events.jsonl"
: > "$events_file"

while IFS=$'\t' read -r user_name key_id status create_date purpose owner customer usage_owner key_alias; do
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
          eventId: (.eventID // null),
          credentialType: "access-key",
          userName: $user,
          accessKeyId: $key,
          serviceCredentialId: null,
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

while IFS=$'\t' read -r user_name credential_id status create_date service_name purpose owner customer usage_owner key_alias; do
  [[ "$status" == "Active" ]] || continue
  next_token=""
  page=0
  while [[ $page -lt $MAX_PAGES ]]; do
    args=(cloudtrail lookup-events
      --region "$REGION"
      --lookup-attributes "AttributeKey=Username,AttributeValue=$user_name"
      --start-time "$START_TIME"
      --end-time "$END_TIME"
      --max-results 50
      --output json)
    if [[ -n "$next_token" ]]; then
      args+=(--next-token "$next_token")
    fi
    page_json=$(aws_operator "${args[@]}")
    printf '%s' "$page_json" | jq -c --arg user "$user_name" --arg credential "$credential_id" '
      .Events[]?
      | (.CloudTrailEvent | fromjson?)
      | select(.eventSource == "bedrock.amazonaws.com")
      | {
          eventId: (.eventID // null),
          credentialType: "bearer",
          userName: $user,
          accessKeyId: null,
          serviceCredentialId: $credential,
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
done < "$service_credentials_file"

if [[ -s "$events_file" ]]; then
  unique_events_file="$tmp_dir/events-unique.jsonl"
  jq -sc '. | unique_by((.eventId // "") + ":" + (.credentialType // "") + ":" + (.userName // "") + ":" + (.eventTime // "") + ":" + (.eventName // "")) | .[]' "$events_file" > "$unique_events_file"
  mv "$unique_events_file" "$events_file"
fi

event_count=$(wc -l < "$events_file" | tr -d ' ')
echo "bedrock_events=$event_count"
if [[ "$event_count" != "0" ]]; then
  echo "by_credential="
  jq -sr '
    group_by((.credentialType // "") + ":" + (.userName // "") + ":" + (.accessKeyId // .serviceCredentialId // "unknown"))
    | .[]
    | {
        type: .[0].credentialType,
        id: ((.[0].accessKeyId // .[0].serviceCredentialId // "unknown") as $id | if ($id | length) > 12 then ($id[0:8] + "..." + $id[-4:]) else $id end),
        user: .[0].userName,
        events: length,
        errors: map(select(.errorCode != null)) | length
      }
    | "  type=\(.type) id=\(.id) user=\(.user) events=\(.events) errors=\(.errors)"
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
    | (.accessKeyId // .serviceCredentialId // "unknown") as $id
    | "  \(.eventTime) \(.eventName) type=\(.credentialType) id=\(if ($id | length) > 12 then ($id[0:8] + "..." + $id[-4:]) else $id end) model=\(.modelId // "unknown") error=\(.errorCode // "none")"
  ' "$events_file"
fi
echo

echo "== CloudWatch and Bedrock logging diagnostics =="
if metrics_json=$(aws_operator cloudwatch list-metrics --region "$REGION" --namespace AWS/Bedrock --max-items 50 --output json 2>/tmp/bedrock_usage_metrics_error.txt); then
  metrics_count=$(printf '%s' "$metrics_json" | jq '(.Metrics // []) | length')
  echo "cloudwatch_list_metrics=ok count=$metrics_count"
  printf '%s' "$metrics_json" | jq -r '(.Metrics // [])[:10][] | "  metric=\(.MetricName) dimensions=\(.Dimensions | map(.Name + "=" + .Value) | join(","))"'

  if [[ "$metrics_count" != "0" ]]; then
    metric_queries=$(printf '%s' "$metrics_json" | jq -c --argjson period 3600 '
      (.Metrics // [])[:5]
      | to_entries
      | map({
          Id: ("m" + (.key | tostring)),
          Label: (
            .value.MetricName
            + " "
            + ((.value.Dimensions // []) | map(.Name + "=" + .Value) | join(","))
          ),
          MetricStat: {
            Metric: {
              Namespace: "AWS/Bedrock",
              MetricName: .value.MetricName,
              Dimensions: (.value.Dimensions // [])
            },
            Period: $period,
            Stat: "Sum"
          },
          ReturnData: true
        })
    ')
    if metric_data_json=$(aws_operator cloudwatch get-metric-data \
        --region "$REGION" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --metric-data-queries "$metric_queries" \
        --output json 2>/tmp/bedrock_usage_metric_data_error.txt); then
      echo "cloudwatch_get_metric_data=ok"
      printf '%s' "$metric_data_json" | jq -r '
        (.MetricDataResults // [])[]
        | {
            label: .Label,
            points: ((.Values // []) | length),
            sum: ((.Values // []) | add // 0),
            latest: ((.Values // [])[0] // "none")
          }
        | "  metric=\(.label) points=\(.points) sum=\(.sum) latest=\(.latest)"
      '
    else
      echo "cloudwatch_get_metric_data=unavailable"
      sed 's/^/  /' /tmp/bedrock_usage_metric_data_error.txt
    fi
  else
    echo "cloudwatch_get_metric_data=skipped no_metrics"
  fi
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
echo

echo "== Invocation log token usage =="
echo "window=${HOURS}h start=$START_TIME end=$END_TIME"
if [[ -z "$INVOCATION_LOG_GROUP" ]]; then
  echo "invocation_log_group=not_configured"
  echo "token_usage=skipped"
  echo "hint=set BEDROCK_USAGE_INVOCATION_LOG_GROUP or pass --invocation-log-group to aggregate token counts from CloudWatch Logs"
else
  echo "invocation_log_group=$INVOCATION_LOG_GROUP"
  query_file="$tmp_dir/invocation-log-query.txt"
  invocation_rows_file="$tmp_dir/invocation-log-token-rows.jsonl"
  : > "$invocation_rows_file"
  cat > "$query_file" <<QUERY
fields identity.arn as principal,
       modelId,
       operation,
       requestMetadata.customer as customer,
       requestMetadata.usageOwner as usageOwner,
       requestMetadata.keyAlias as keyAlias,
       input.inputTokenCount as inputTokens,
       output.outputTokenCount as outputTokens,
       input.cacheReadInputTokenCount as cacheReadTokens,
       input.cacheWriteInputTokenCount as cacheWriteTokens
| stats count(*) as calls,
        sum(inputTokens) as inputTokens,
        sum(outputTokens) as outputTokens,
        sum(cacheReadTokens) as cacheReadTokens,
        sum(cacheWriteTokens) as cacheWriteTokens
        by principal, customer, usageOwner, keyAlias, modelId
| sort calls desc
| limit $INVOCATION_LOG_LIMIT
QUERY

  log_group_args=(--log-group-name "$INVOCATION_LOG_GROUP")
  if [[ "$INVOCATION_LOG_GROUP" == arn:* ]]; then
    log_group_args=(--log-group-identifiers "$INVOCATION_LOG_GROUP")
  fi

  if query_json=$(aws_operator logs start-query \
      "${log_group_args[@]}" \
      --start-time "$START_EPOCH" \
      --end-time "$END_EPOCH" \
      --query-string "$(cat "$query_file")" \
      --output json 2>/tmp/bedrock_usage_invocation_logs_error.txt); then
    query_id=$(printf '%s' "$query_json" | jq -r '.queryId')
    echo "query_id=$query_id"
    query_status="Unknown"
    query_results_json=""
    deadline=$((SECONDS + INVOCATION_LOG_QUERY_TIMEOUT_SECONDS))
    while [[ "$SECONDS" -le "$deadline" ]]; do
      query_results_json=$(aws_operator logs get-query-results --query-id "$query_id" --output json 2>/tmp/bedrock_usage_invocation_logs_error.txt)
      query_status=$(printf '%s' "$query_results_json" | jq -r '.status')
      case "$query_status" in
        Complete)
          break
          ;;
        Failed|Cancelled|Timeout)
          break
          ;;
      esac
      sleep 2
    done

    echo "query_status=$query_status"
    if [[ "$query_status" == "Complete" ]]; then
      principal_prefix=":user$CUSTOMER_PATH"
      printf '%s' "$query_results_json" | jq -c --arg prefix "$principal_prefix" '
        .results[]?
        | map({key: .field, value: .value}) | from_entries
        | select((.principal // "") | contains($prefix))
      ' > "$invocation_rows_file"

      scoped_row_count=$(wc -l < "$invocation_rows_file" | tr -d ' ')
      raw_row_count=$(printf '%s' "$query_results_json" | jq '(.results // []) | length')
      echo "raw_groups=$raw_row_count scoped_groups=$scoped_row_count"

      if [[ "$scoped_row_count" != "0" ]]; then
        jq -sr '
          def n($v): (($v // "0") | tonumber? // 0);
          {
            calls: (map(n(.calls)) | add // 0),
            input: (map(n(.inputTokens)) | add // 0),
            output: (map(n(.outputTokens)) | add // 0),
            cacheRead: (map(n(.cacheReadTokens)) | add // 0),
            cacheWrite: (map(n(.cacheWriteTokens)) | add // 0)
          }
          | "total_calls=\(.calls) input_tokens=\(.input) output_tokens=\(.output) cache_read_tokens=\(.cacheRead) cache_write_tokens=\(.cacheWrite)"
        ' "$invocation_rows_file"
        echo "by_principal_model="
        jq -sr '
          def n($v): (($v // "0") | tonumber? // 0);
          def clean($v): if ($v == null or $v == "") then "-" else $v end;
          sort_by(-(n(.calls)))
          | .[]
          | {
              principal: ((.principal // "") | split("/") | last),
              customer: clean(.customer),
              usageOwner: clean(.usageOwner),
              keyAlias: clean(.keyAlias),
              modelId: clean(.modelId),
              calls: n(.calls),
              input: n(.inputTokens),
              output: n(.outputTokens),
              cacheRead: n(.cacheReadTokens),
              cacheWrite: n(.cacheWriteTokens)
            }
          | "  user=\(.principal) customer=\(.customer) usageOwner=\(.usageOwner) keyAlias=\(.keyAlias) model=\(.modelId) calls=\(.calls) input=\(.input) output=\(.output) cacheRead=\(.cacheRead) cacheWrite=\(.cacheWrite)"
        ' "$invocation_rows_file"
      else
        echo "token_usage=none_for_customer_path"
      fi
    else
      echo "token_usage=unavailable"
    fi
  else
    echo "token_usage=unavailable"
    sed 's/^/  /' /tmp/bedrock_usage_invocation_logs_error.txt
  fi
fi
