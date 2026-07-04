#!/bin/bash
# 向 Cloudflare GraphQL Analytics 查詢 Worker 觀測數據
#   注意：GraphQL analytics 有數分鐘傳播延遲，適合「事後／持續」觀測；
#         部署當下的即時健康信號請以 deploy.sh 的直連 curl 為準。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# 統一憑證載入（自動讀 .env，相容 CLOUDFLARE_* 與 CF_*）
if ! load_cf_credentials; then
    emit_json_result "false" "Missing Cloudflare credentials." "{}"
    exit 1
fi

SCRIPT_NAME="${SCRIPT_NAME:-mvp-worker}"
WINDOW_MINUTES="${METRICS_WINDOW_MINUTES:-5}"

log_info "開始向 Cloudflare 查詢觀測數據 (Worker: $SCRIPT_NAME)..."

# 1. UTC 時間範圍（可攜式，相容 GNU / BSD date）
SINCE=$(utc_minutes_ago "$WINDOW_MINUTES")
UNTIL=$(utc_now)
log_info "查詢時間區間 (UTC): $SINCE ~ $UNTIL"

# 2. GraphQL 查詢
QUERY_JSON=$(cat <<EOF
{
  "query": "query GetWorkerMetrics(\$accountTag: String!, \$scriptName: String!, \$since: Time!, \$until: Time!) { viewer { accounts(filter: { accountTag: \$accountTag }) { workersInvocationsAdaptive(limit: 1, filter: { scriptName: \$scriptName, datetime_geq: \$since, datetime_leq: \$until }) { sum { requests errors } quantiles { durationP90 } } } } }",
  "variables": {
    "accountTag": "$CF_ACCOUNT_ID",
    "scriptName": "$SCRIPT_NAME",
    "since": "$SINCE",
    "until": "$UNTIL"
  }
}
EOF
)

# 3. 發送請求（附帶 HTTP 狀態碼）
RESPONSE=$(curl -s -w $'\n%{http_code}' -X POST "https://api.cloudflare.com/client/v4/graphql" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$QUERY_JSON")
HTTP_CODE=$(printf '%s' "$RESPONSE" | tail -n1)
BODY=$(printf '%s' "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
    log_error "Cloudflare GraphQL API 回應非 200 (HTTP ${HTTP_CODE:-N/A})"
    emit_json_result "false" "API communication failed (HTTP ${HTTP_CODE:-N/A})." "{}"
    exit 1
fi

# 4. body 需為合法 JSON
if ! printf '%s' "$BODY" | jq -e . >/dev/null 2>&1; then
    log_error "回應不是合法 JSON"
    emit_json_result "false" "Invalid JSON response from API." "{}"
    exit 1
fi

# 5. 檢查 GraphQL 層級錯誤
HAS_ERRORS=$(printf '%s' "$BODY" | jq -c '.errors // empty')
if [ -n "$HAS_ERRORS" ] && [ "$HAS_ERRORS" != "[]" ]; then
    log_error "GraphQL 查詢錯誤或權限不足！"
    emit_json_result "false" "GraphQL execution error." "$HAS_ERRORS"
    exit 1
fi

# 6. 解析指標（null-safe，防除以 0；無資料時給明確 note）
METRICS_DATA=$(printf '%s' "$BODY" | jq -c '
  ((.data.viewer.accounts // []) | .[0] // {} | (.workersInvocationsAdaptive // []) | .[0]) as $m
  | if $m == null then
      { "request_count": 0, "error_rate": 0.0, "p90_latency": 0.0, "note": "Data propagation delay or no traffic" }
    else
      {
        "request_count": ($m.sum.requests // 0),
        "error_rate": (if ($m.sum.requests // 0) > 0 then (($m.sum.errors // 0) / $m.sum.requests) else 0.0 end),
        "p90_latency": ($m.quantiles.durationP90 // 0.0)
      }
    end
')

log_info "數據擷取與分析完成。"
emit_json_result "true" "Metrics retrieved successfully." "$METRICS_DATA"
