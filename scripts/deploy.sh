#!/bin/bash
# Task 4：自動化發佈與健康閘門
# 憑證：若用 API token，請設定 CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID
#       （wrangler 會自行讀取）；若用 `wrangler login` OAuth 則不需環境變數。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

log_info "開始執行 Task 4: 自動化發佈與健康閘門..."

# 0. 前置閘門：測試與型別檢查
log_info "正在執行測試閘門 (npm test)..."
TEST_OUTPUT=$(npm test -- --run 2>&1)
TEST_STATUS=$?
if [ $TEST_STATUS -ne 0 ]; then
    log_error "測試未通過，中止部署！"
    echo "$TEST_OUTPUT" >&2
    DATA_ERR='{"required_action": "fix_tests", "reason": "Test suite failed"}'
    emit_json_result "false" "Pre-deploy gate: tests failed." "$DATA_ERR"
    exit 1
fi
log_info "測試全部通過。"

log_info "正在執行型別檢查閘門 (tsc)..."
TSC_OUTPUT=$(npx tsc --noEmit 2>&1)
TSC_STATUS=$?
if [ $TSC_STATUS -ne 0 ]; then
    log_error "TypeScript 型別檢查未通過，中止部署！"
    echo "$TSC_OUTPUT" >&2
    DATA_ERR='{"required_action": "fix_types", "reason": "TypeScript compilation failed"}'
    emit_json_result "false" "Pre-deploy gate: type check failed." "$DATA_ERR"
    exit 1
fi
log_info "型別檢查通過。"

# 1. 執行部署
log_info "正在啟動 npx wrangler deploy..."
DEPLOY_OUTPUT=$(npx wrangler deploy --keep-vars 2>&1)
DEPLOY_STATUS=$?

if [ $DEPLOY_STATUS -ne 0 ]; then
    log_error "Wrangler 部署硬性失敗！"
    echo "$DEPLOY_OUTPUT" >&2
    DATA_ERR='{"required_action": "rollback", "reason": "Wrangler CLI execution failed"}'
    emit_json_result "false" "Deployment blocked at build/upload stage." "$DATA_ERR"
    exit 1
fi

log_info "Wrangler 上傳成功，正在決定健康檢查端點..."

# 2. 決定健康檢查 URL
#    優先用環境變數 HEALTH_URL（支援自訂網域 / route，最可靠）；
#    否則從 wrangler 輸出解析 workers.dev，再退而抓任何 https URL。
if [ -n "${HEALTH_URL:-}" ]; then
    TARGET_URL="$HEALTH_URL"
    log_info "使用環境變數指定的健康檢查 URL: $TARGET_URL"
else
    TARGET_URL=$(echo "$DEPLOY_OUTPUT" | grep -oE 'https://[a-zA-Z0-9._-]+\.workers\.dev' | head -n1)
    if [ -z "$TARGET_URL" ]; then
        TARGET_URL=$(echo "$DEPLOY_OUTPUT" | grep -oE 'https://[a-zA-Z0-9._/-]+' | head -n1)
    fi
fi

if [ -z "$TARGET_URL" ]; then
    log_error "無法決定健康檢查端點。請設定環境變數 HEALTH_URL 指向線上服務。"
    DATA_ERR='{"required_action": "rollback", "reason": "Cannot determine health endpoint; set HEALTH_URL"}'
    emit_json_result "false" "Health endpoint resolution failed." "$DATA_ERR"
    exit 1
fi

HEALTH_PATH="${HEALTH_PATH:-/health}"
HEALTH_ENDPOINT="${TARGET_URL%/}${HEALTH_PATH}"
log_info "已鎖定線上健康檢查閘門: $HEALTH_ENDPOINT"

# 3. 高韌性冒煙測試（皆可用環境變數覆蓋）
MAX_CHECKS="${SMOKE_CHECKS:-3}"         # 需連續成功的輪數
MAX_RETRIES="${SMOKE_RETRIES:-3}"       # 單輪容錯重試次數
RETRY_INTERVAL="${SMOKE_RETRY_GAP:-2}"  # 重試間隔（秒）
ROUND_GAP="${SMOKE_ROUND_GAP:-5}"       # 輪與輪之間隔（秒）→ 讓「連續穩定」跨越時間

# ==========================================================
# [新增] 邊緣節點同步熱身延遲 (Smoke Warmup)
# ==========================================================
SMOKE_WARMUP="${SMOKE_WARMUP:-5}"       # 預設掛起 5 秒
if [ "$SMOKE_WARMUP" -gt 0 ]; then
    log_info "等待 Cloudflare 邊緣節點代碼同步，掛起 ${SMOKE_WARMUP} 秒..."
    sleep "$SMOKE_WARMUP"
fi
# ==========================================================

log_info "啟動邊緣健康驗證：要求連續成功 $MAX_CHECKS 輪（每輪間隔 ${ROUND_GAP}s）..."

HTTP_STATUS="000"
for ((check=1; check<=MAX_CHECKS; check++)); do
    log_info "第 $check / $MAX_CHECKS 輪邊緣節點探測..."
    round_passed=false
    for ((retry=1; retry<=MAX_RETRIES; retry++)); do
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$HEALTH_ENDPOINT")
        HTTP_STATUS="${HTTP_STATUS:-000}"
        if [ "$HTTP_STATUS" = "200" ]; then
            log_info "-> 第 $check 輪探測成功 (HTTP 200)"
            round_passed=true
            break
        else
            log_error "-> 探測異常! HTTP: $HTTP_STATUS (嘗試 $retry/$MAX_RETRIES)"
            if [ $retry -lt $MAX_RETRIES ]; then
                log_info "疑似網路抖動，等待 ${RETRY_INTERVAL}s 後容錯重試..."
                sleep "$RETRY_INTERVAL"
            fi
        fi
    done

    # 關鍵決策點：某輪歷經所有重試仍失敗 → 判定重大故障
    if [ "$round_passed" = false ]; then
        log_error "【警告】新版本未能通過邊緣健康閘門！"
        DATA_ROLLBACK=$(cat <<EOF
{
  "required_action": "rollback",
  "failed_at_round": $check,
  "last_http_status": "$HTTP_STATUS",
  "target_url": "$HEALTH_ENDPOINT",
  "timestamp": $(date +%s)
}
EOF
)
        emit_json_result "false" "Smoke test gate verification failed. Service unstable." "$DATA_ROLLBACK"
        exit 1
    fi

    # 除最後一輪外，輪間留間隔
    if [ $check -lt $MAX_CHECKS ]; then
        sleep "$ROUND_GAP"
    fi
done

log_info "所有邊緣健康閘門均已通過！"
DATA_STABLE=$(cat <<EOF
{
  "required_action": "none",
  "deployed_url": "$TARGET_URL",
  "health_endpoint": "$HEALTH_ENDPOINT",
  "status": "stable",
  "total_checks_passed": $MAX_CHECKS
}
EOF
)
emit_json_result "true" "Deployment lifecycle completed successfully." "$DATA_STABLE"
