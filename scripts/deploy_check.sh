#!/bin/bash
# 部署前檢查：本地 dev worker 健康檢查
#   用途：wrangler deploy 之前，確認本地 `wrangler dev` 起得來且 /health 正常。
#   與 deploy.sh 的差異 —— 這支檢查「本地開發實例」，deploy.sh 檢查「已上線的邊緣」。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# 本地端點可用環境變數覆蓋，預設為 wrangler dev 的 localhost:8787
LOCAL_URL="${LOCAL_HEALTH_URL:-http://localhost:8787/health}"

log_info "開始執行部署前基礎設施檢查..."
log_info "正在請求本地 Worker 端點: $LOCAL_URL"

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$LOCAL_URL")
HTTP_STATUS="${HTTP_STATUS:-000}"

if [ "$HTTP_STATUS" = "200" ]; then
    log_info "本地健康檢查成功 (HTTP 200)！"
    EXTRA_DATA=$(cat <<EOF
{
  "service": "${SCRIPT_NAME:-mvp-worker}",
  "type": "cloudflare-worker",
  "checked_url": "$LOCAL_URL",
  "http_status": "$HTTP_STATUS"
}
EOF
)
    emit_json_result "true" "Local worker is ready and healthy." "$EXTRA_DATA"
else
    log_error "無法連線至本地 Worker 端點 (HTTP $HTTP_STATUS)。請先啟動 npx wrangler dev。"
    DATA_ERR=$(cat <<EOF
{
  "checked_url": "$LOCAL_URL",
  "http_status": "$HTTP_STATUS",
  "hint": "Start 'npx wrangler dev' before running the pre-deploy check"
}
EOF
)
    emit_json_result "false" "Local health check failed." "$DATA_ERR"
    exit 1
fi
