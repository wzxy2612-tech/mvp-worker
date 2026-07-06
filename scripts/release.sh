#!/bin/bash
# ==========================================================
# release.sh — Master 發佈流程編排
#   串起 backup → deploy（內含健康閘門）→ 失敗自動 rollback
#   讀各子腳本 stdout 的 JSON，依 success / required_action 分支。
#   自身遵守契約：一般 log 走 stderr，最終 summary JSON 走 stdout。
#   請於「專案根目錄」執行（wrangler.jsonc 與 ./backups 皆相對於 CWD）。
# ==========================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# 從 JSON 取欄位（找不到回空字串，不噴錯）
jget() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }
is_json() { printf '%s' "$1" | jq -e . >/dev/null 2>&1; }

log_info "=========== 發佈流程開始 ==========="

# ---------- 1. 備份 ----------
log_info "[1/3] 執行 backup.sh ..."
BACKUP_OUT=$(bash "$SCRIPT_DIR/backup.sh")
BACKUP_RC=$?
BACKUP_OK=$(jget "$BACKUP_OUT" '.success')

if [ $BACKUP_RC -ne 0 ] || [ "$BACKUP_OK" != "true" ]; then
    log_error "備份失敗，中止發佈（不在無備份的情況下部署）。"
    echo "$BACKUP_OUT" >&2
    if is_json "$BACKUP_OUT"; then BR="$BACKUP_OUT"; else BR="null"; fi
    DATA=$(jq -cn --argjson br "$BR" '{stage:"backup", backup_result:$br}')
    emit_json_result "false" "Release aborted: backup stage failed." "$DATA"
    exit 1
fi

BACKUP_CONF_NAME=$(jget "$BACKUP_OUT" '.data.local_config_backup')
BACKUP_BASE_DIR=$(jget "$BACKUP_OUT" '.data.backup_directory')
BACKUP_CONFIG_PATH=""
if [ -n "$BACKUP_CONF_NAME" ] && [ "$BACKUP_CONF_NAME" != "null" ]; then
    BACKUP_CONFIG_PATH="${BACKUP_BASE_DIR%/}/$BACKUP_CONF_NAME"
    log_info "備份完成，設定檔快照: $BACKUP_CONFIG_PATH"
fi

# ---------- 2. 部署（含健康閘門）----------
log_info "[2/3] 執行 deploy.sh（內含冒煙測試健康閘門）..."
DEPLOY_OUT=$(bash "$SCRIPT_DIR/deploy.sh")
DEPLOY_RC=$?
DEPLOY_OK=$(jget "$DEPLOY_OUT" '.success')
REQUIRED_ACTION=$(jget "$DEPLOY_OUT" '.data.required_action')

# ---------- 3. 分支：成功 or 觸發回滾 ----------
if [ "$DEPLOY_OK" = "true" ] && [ "$REQUIRED_ACTION" != "rollback" ]; then
    DEPLOYED_URL=$(jget "$DEPLOY_OUT" '.data.deployed_url')
    log_info "[3/3] 部署成功且通過健康閘門 ✅  ($DEPLOYED_URL)"
    log_info "=========== 發佈流程完成 ==========="
    DATA=$(jq -cn --arg url "$DEPLOYED_URL" --arg cfg "$BACKUP_CONFIG_PATH" \
      '{stage:"deployed", deployed_url:$url, backup_config: (($cfg | select(length>0)) // null)}')
    emit_json_result "true" "Release completed successfully." "$DATA"
    exit 0
fi

# 走到這裡 = 部署硬失敗，或健康閘門要求回滾
log_error "[3/3] 部署未通過 (success=$DEPLOY_OK, required_action=$REQUIRED_ACTION) → 觸發自動回滾..."
echo "$DEPLOY_OUT" >&2

ROLLBACK_OUT=$(bash "$SCRIPT_DIR/rollback.sh" "" "$BACKUP_CONFIG_PATH")
ROLLBACK_RC=$?
ROLLBACK_OK=$(jget "$ROLLBACK_OUT" '.success')

if [ $ROLLBACK_RC -ne 0 ] || [ "$ROLLBACK_OK" != "true" ]; then
    log_error "【災難】自動回滾亦失敗，需人工介入！"
    echo "$ROLLBACK_OUT" >&2
    emit_json_result "false" "CRITICAL: deploy failed AND rollback failed. Manual intervention required." \
      '{"stage":"rollback_failed","required_action":"manual_intervention"}'
    exit 2
fi

log_error "部署失敗，但自動回滾成功，系統已恢復上一穩定版本。"
log_info "=========== 發佈流程結束（已回滾）==========="
emit_json_result "false" "Release failed; system automatically rolled back to previous stable version." \
  '{"stage":"rolled_back","required_action":"manual_review_code"}'
exit 1
