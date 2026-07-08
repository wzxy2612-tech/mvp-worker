#!/bin/bash
# Task 5：自動回滾機制
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

log_info "開始執行 Task 5: 自動回滾機制 (Automated Rollback)..."

# 用法：bash rollback.sh <PREVIOUS_VERSION_ID> <BACKUP_CONFIG_FILE>
PREV_VERSION="${1:-}"
BACKUP_CONFIG="${2:-}"
ROLLBACK_MSG="Automated rollback triggered by pipeline health gate"

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