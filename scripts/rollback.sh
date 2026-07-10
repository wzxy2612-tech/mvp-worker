#!/bin/bash
# Task 5：自動回滾機制
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

log_info "開始執行 Task 5: 自動回滾機制 (Automated Rollback)..."

# ==============================================================================
# 🎯 補盲區小鏟子：向控制面同步回滾審計日誌
# ==============================================================================
send_audit_log() {
    local status_type="$1"
    local msg="$2"
    local disp_ok=0
    local http_st=500

    if [ "$status_type" = "completed" ]; then
        disp_ok=1
        http_st=200
    elif [ "$status_type" = "skipped_no_history" ]; then
        disp_ok=1
        http_st=204
    fi

    # 關鍵防禦：若環境變數未配，優雅跳過不卡死流水線
    if [ -z "${CONTROLLER_URL:-}" ] || [ -z "${TRIGGER_SECRET:-}" ]; then
        log_warn "未配置 CONTROLLER_URL 或 TRIGGER_SECRET，跳過向控制面發送審計通知。"
        return 0
    fi

    log_info "正在向控制面同步回滾審計日誌 (${status_type})..."

    # 利用 json_escape 安全處理 msg，避免 JSON 注入
    local safe_msg
    safe_msg=$(json_escape "$msg")

    local payload
    payload=$(cat <<EOF
{
  "action": "${ROLLBACK_SOURCE:-auto_rollback}",
  "ref": "${CLOUDFLARE_ENV:-default}",
  "trace_id": "${TRACE_ID:-}",
  "dispatch_ok": $disp_ok,
  "http_status": $http_st,
  "detail": "$safe_msg"
}
EOF
)

    local curl_out
    curl_out=$(curl -s -w "\n%{http_code}" -X POST "${CONTROLLER_URL}/audit" \
      -H "Content-Type: application/json" \
      -H "X-Trigger-Secret: ${TRIGGER_SECRET}" \
      --connect-timeout 5 --max-time 10 \
      -d "$payload" 2>&1)

    local curl_status=$?
    if [ $curl_status -eq 0 ]; then
        local http_code
        http_code=$(echo "$curl_out" | tail -n1)
        log_info "控制面審計 API 響應狀態碼: $http_code"
    else
        log_warn "向控制面發送審計日誌失敗，curl 退出碼: $curl_status"
    fi
}

# 用法：bash rollback.sh <PREVIOUS_VERSION_ID> <BACKUP_CONFIG_FILE>
PREV_VERSION="${1:-}"
BACKUP_CONFIG="${2:-}"
# ==============================================================================
# 🎯 修正點：打破審計「說謊」——優先採用傳入參數或環境變數，拒絕一律硬編碼
# ==============================================================================
DEFAULT_MSG="Automated rollback triggered by pipeline health gate"

# 優先級：腳本第 3 個參數 > 環境變數 ROLLBACK_MESSAGE > 預設自動化健康檢查文案
ROLLBACK_MSG="${3:-${ROLLBACK_MESSAGE:-$DEFAULT_MSG}}"

log_info "當前採用的回滾日誌訊息為: \"$ROLLBACK_MSG\""

# ==============================================================================
# 🎯 修正點 1：動態建構 Wrangler 環境參數 (對齊物理隔離環境)
# ==============================================================================
WRANGLER_ARGS=()
if [ -n "$CLOUDFLARE_ENV" ]; then
    log_info "偵測到目標環境變數 CLOUDFLARE_ENV: $CLOUDFLARE_ENV"
    WRANGLER_ARGS+=("--env" "$CLOUDFLARE_ENV")
else
    log_warn "未指定 CLOUDFLARE_ENV，將嘗試對頂層預設環境進行操作..."
fi

log_info "啟動 Cloudflare 邊緣程式碼回滾程序..."

# 1. Cloudflare 原生回滾
# wrangler rollback 預設互動式（會問 y/n）。使用 --yes 跳過確認。
if [ -n "$PREV_VERSION" ]; then
    log_info "偵測到指定歷史版本 ID: $PREV_VERSION，嘗試精確回滾..."
    ROLLBACK_OUTPUT=$(npx wrangler rollback "$PREV_VERSION" --message "$ROLLBACK_MSG" --yes "${WRANGLER_ARGS[@]}" 2>&1)
else
    log_info "未指定版本 ID，退回上一個穩定版本..."
    ROLLBACK_OUTPUT=$(npx wrangler rollback --message "$ROLLBACK_MSG" --yes "${WRANGLER_ARGS[@]}" 2>&1)
fi
ROLLBACK_STATUS=$?

# ==============================================================================
# 🎯 修正點 2：關鍵防禦點升级——捕獲並識別「無歷史版本」的全新環境窄邊界
# ==============================================================================
if [ $ROLLBACK_STATUS -ne 0 ]; then
    # 檢查 Wrangler 錯誤訊息中是否包含無歷史發布、找不到版本或只有單一版本的特徵
    if echo "$ROLLBACK_OUTPUT" | grep -iqE "no.*deployment|not found|only one deployment|cannot rollback"; then
        log_warn "⚠️ 【窄邊界命中】Cloudflare 回滾跳過：環境 '${CLOUDFLARE_ENV:-default}' 可能為全新建立，尚無足夠的歷史版本紀錄可供回退。"
        echo "$ROLLBACK_OUTPUT"
        
        DATA_NO_HISTORY=$(cat <<EOF
{
  "status": "skipped_no_history",
  "message": "Rollback skipped because the target environment has no previous deployment history to revert to.",
  "wrangler_output": "No previous deployments found",
  "environment_targeted": "${CLOUDFLARE_ENV:-default}"
}
EOF
)
        emit_json_result "true" "Rollback handled: No history available for environment '${CLOUDFLARE_ENV:-default}'." "$DATA_NO_HISTORY"

        send_audit_log "skipped_no_history" "Rollback skipped: Target environment has no previous deployment history."

        # 這是可預期的初始邊界，不讓流水線報紅崩潰，優雅退出
        exit 0
    fi

    # 若非上述良性邊界，則判定為真正的硬性失敗（如網路崩潰、Token 失效等）
    log_error "【緊急警告】Cloudflare 回滾操作硬性失敗！"
    echo "$ROLLBACK_OUTPUT" >&2
    DATA_CRITICAL=$(cat <<EOF
{
  "status": "critical_failure",
  "message": "Rollback failed, manual intervention required",
  "wrangler_error": "CLI execution error",
  "environment_targeted": "${CLOUDFLARE_ENV:-default}"
}
EOF
)
    emit_json_result "false" "CRITICAL: Automated rollback collapsed. Edge state is unknown." "$DATA_CRITICAL"

    send_audit_log "critical_failure" "CRITICAL: Automated rollback failed during wrangler execution."

    exit 2
fi

log_info "Cloudflare 程式碼版本已成功撤回！"

# 2. 還原配置檔快照（支援 jsonc / json / toml，與 backup.sh 對稱）
CONFIG_RESTORED="false"
if [ -n "$BACKUP_CONFIG" ] && [ -f "$BACKUP_CONFIG" ]; then
    log_info "偵測到備份設定檔: $BACKUP_CONFIG，啟動配置還原..."
    case "$BACKUP_CONFIG" in
        *.jsonc|*.json)
            cp "$BACKUP_CONFIG" ./wrangler.jsonc
            CONFIG_RESTORED="true"
            log_info "已還原 -> wrangler.jsonc"
            ;;
        *.toml)
            cp "$BACKUP_CONFIG" ./wrangler.toml
            CONFIG_RESTORED="true"
            log_info "已還原 -> wrangler.toml"
            ;;
        *)
            log_error "無法識別的備份設定檔格式，跳過配置還原: $BACKUP_CONFIG"
            ;;
    esac
else
    log_info "未提供或找不到設定檔快照，跳過配置還原。"
fi

# 說明：還原的是「本地」設定檔，供下次部署使用；
if [ "$CONFIG_RESTORED" = "true" ]; then
    log_info "提醒：本地設定檔已還原；若需讓路由／變數等配置生效，請於確認後另行部署。"
fi

# 3. 成功輸出
log_info "自動回滾程序完成，程式碼已恢復至上一穩定版本。"

send_audit_log "completed" "Rollback successfully executed and code reverted to the previous stable version."

DATA_SUCCESS=$(cat <<EOF
{
  "status": "rollback_completed",
  "required_action": "manual_review_code",
  "previous_version_targeted": "${PREV_VERSION:-latest_stable}",
  "environment_targeted": "${CLOUDFLARE_ENV:-default}",
  "config_restored": $CONFIG_RESTORED,
  "timestamp": $(date +%s)
}
EOF
)
emit_json_result "true" "System successfully recovered to the previous stable state." "$DATA_SUCCESS"