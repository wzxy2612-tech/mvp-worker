#!/bin/bash
# ==========================================================
# promote.sh — 分級晉級發佈：staging → (人工審批) → production
#   [0] 備份一次（快照供任一級回滾還原設定）
#   [1] 部署並驗證 STAGING（沿用 deploy.sh 的雙閘門 + 邊緣健康門）
#   [2] 擷取 STAGING 指標 → 停下等人工輸入 yes 才繼續
#   [3] 部署 PRODUCTION（各自健康門），失敗自動回滾 production
#   全程走 JSON 契約：一般 log / 提示走 stderr，最終 summary JSON 走 stdout。
#   透過 CLOUDFLARE_ENV 切環境，不改任何現有腳本。於專案根目錄執行。
# ==========================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

jget() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

WORKER_NAME="${WORKER_NAME:-mvp-worker}"
STAGING_SCRIPT="${WORKER_NAME}-staging"
PRODUCTION_SCRIPT="${WORKER_NAME}-production"

log_info "=========== 晉級發佈開始 (staging → production) ==========="

# ---------- 0. 備份（一次）----------
log_info "[0] 執行 backup.sh ..."
BACKUP_OUT=$(bash "$SCRIPT_DIR/backup.sh")
if [ $? -ne 0 ] || [ "$(jget "$BACKUP_OUT" '.success')" != "true" ]; then
    log_error "備份失敗，中止晉級（不在無備份下發佈）。"
    echo "$BACKUP_OUT" >&2
    emit_json_result "false" "Promotion aborted: backup failed." '{"stage":"backup"}'
    exit 1
fi
BACKUP_CONF_NAME=$(jget "$BACKUP_OUT" '.data.local_config_backup')
BACKUP_BASE_DIR=$(jget "$BACKUP_OUT" '.data.backup_directory')
BACKUP_CONFIG_PATH=""
if [ -n "$BACKUP_CONF_NAME" ] && [ "$BACKUP_CONF_NAME" != "null" ]; then
    BACKUP_CONFIG_PATH="${BACKUP_BASE_DIR%/}/$BACKUP_CONF_NAME"
fi
log_info "備份完成：${BACKUP_CONFIG_PATH:-<none>}"

# ---------- 1. Phase 1：部署 + 驗證 STAGING ----------
log_info "[1] 部署並驗證 STAGING（$STAGING_SCRIPT）..."
STAGING_OUT=$(SMOKE_WARMUP=3 CLOUDFLARE_ENV=staging bash "$SCRIPT_DIR/deploy.sh")
STAGING_OK=$(jget "$STAGING_OUT" '.success')
STAGING_ACTION=$(jget "$STAGING_OUT" '.data.required_action')

if [ "$STAGING_OK" != "true" ] || [ "$STAGING_ACTION" = "rollback" ]; then
    log_error "STAGING 未通過（success=$STAGING_OK, action=$STAGING_ACTION）→ 回滾 staging 並中止晉級。"
    echo "$STAGING_OUT" >&2
    CLOUDFLARE_ENV=staging bash "$SCRIPT_DIR/rollback.sh" "" "$BACKUP_CONFIG_PATH" >&2
    emit_json_result "false" "Promotion aborted: staging failed and was rolled back." \
      '{"stage":"staging","required_action":"manual_review_code"}'
    exit 1
fi
STAGING_URL=$(jget "$STAGING_OUT" '.data.deployed_url')
log_info "STAGING 已上線並通過健康門 ✅  ($STAGING_URL)"

# ---------- 2. STAGING 指標 + 人工審批 ----------
log_info "[2] 擷取 STAGING 指標供審批參考（$STAGING_SCRIPT）..."
METRICS_OUT=$(SCRIPT_NAME="$STAGING_SCRIPT" bash "$SCRIPT_DIR/get_metrics.sh" 2>/dev/null)
if [ "$(jget "$METRICS_OUT" '.success')" = "true" ]; then
    M_REQ=$(jget "$METRICS_OUT" '.data.request_count')
    M_ERR=$(jget "$METRICS_OUT" '.data.error_rate')
    M_P90=$(jget "$METRICS_OUT" '.data.p90_latency')
    M_NOTE=$(jget "$METRICS_OUT" '.data.note'); [ "$M_NOTE" = "null" ] && M_NOTE=""
    log_info "  STAGING 指標 → requests=$M_REQ  error_rate=$M_ERR  p90=$M_P90${M_NOTE:+  ($M_NOTE)}"
else
    log_info "  (指標暫不可用；analytics 有數分鐘延遲，或憑證未設；不影響審批)"
fi

# ---------- 2.5 STAGING 審批閘門 (支援本機與 CI 雙模式) ----------
# 互動式 TTY（本機）→ 終端機提示，等待輸入 yes/y
# 非互動式（CI）→ 跳過 read，需顯式傳入 PROMOTE_APPROVE=yes 才放行，否則安全中止
if [ -t 0 ]; then
    printf '\n>>> STAGING 已就緒：%s\n>>> 確認晉級到 PRODUCTION？輸入 yes 繼續，其它任意鍵放棄： ' "$STAGING_URL" >&2
    read -r APPROVAL
    if ! [[ "$APPROVAL" =~ ^[yY]([eE][sS])?$ ]]; then
        log_info "使用者未批准，停在 staging，production 不動。"
        emit_json_result "true" "Promotion stopped at staging by user (production unchanged)." \
          "$(jq -cn --arg u "$STAGING_URL" '{stage:"staging_only", staging_url:$u, approved:false}')"
        exit 0
    fi
elif [[ "${PROMOTE_APPROVE:-}" =~ ^[yY]([eE][sS])?$ ]]; then
    log_info "非互動式環境：偵測到 PROMOTE_APPROVE=yes，視為已審批（信任 CI 平台閘門）。"
else
    log_error "非互動式環境且未設 PROMOTE_APPROVE=yes → 為避免靜默略過，安全中止晉級。"
    emit_json_result "false" "Promotion aborted: non-interactive shell without explicit approval." \
      "$(jq -cn --arg u "$STAGING_URL" '{stage:"staging_only", staging_url:$u, approved:false, required_action:"set_PROMOTE_APPROVE_or_run_interactively"}')"
    exit 1
fi
log_info "已獲批准，開始晉級到 PRODUCTION..."

# ---------- 3. Phase 2：部署 PRODUCTION（失敗自動回滾）----------
log_info "[3] 部署 PRODUCTION（$PRODUCTION_SCRIPT）..."
PROD_OUT=$(SMOKE_WARMUP=10 CLOUDFLARE_ENV=production bash "$SCRIPT_DIR/deploy.sh")
PROD_OK=$(jget "$PROD_OUT" '.success')
PROD_ACTION=$(jget "$PROD_OUT" '.data.required_action')

if [ "$PROD_OK" = "true" ] && [ "$PROD_ACTION" != "rollback" ]; then
    PROD_URL=$(jget "$PROD_OUT" '.data.deployed_url')
    log_info "PRODUCTION 已上線並通過健康門 ✅  ($PROD_URL)"
    log_info "=========== 晉級發佈完成 ==========="
    DATA=$(jq -cn --arg s "$STAGING_URL" --arg p "$PROD_URL" \
      '{stage:"promoted", staging_url:$s, production_url:$p, approved:true}')
    emit_json_result "true" "Promotion completed: staging -> production." "$DATA"
    exit 0
fi

# production 未通過 → 自動回滾 production
log_error "PRODUCTION 未通過（success=$PROD_OK, action=$PROD_ACTION）→ 觸發 production 自動回滾..."
echo "$PROD_OUT" >&2
ROLLBACK_OUT=$(CLOUDFLARE_ENV=production bash "$SCRIPT_DIR/rollback.sh" "" "$BACKUP_CONFIG_PATH")
ROLLBACK_OK=$(jget "$ROLLBACK_OUT" '.success')

if [ "$ROLLBACK_OK" != "true" ]; then
    log_error "【災難】production 回滾亦失敗，需人工介入！"
    echo "$ROLLBACK_OUT" >&2
    emit_json_result "false" "CRITICAL: production deploy failed AND rollback failed. Manual intervention required." \
      '{"stage":"production_rollback_failed","required_action":"manual_intervention"}'
    exit 2
fi

log_error "production 部署失敗，但已自動回滾至上一穩定版本（staging 仍在線）。"
log_info "=========== 晉級發佈結束（production 已回滾）==========="
emit_json_result "false" "Production promotion failed; production rolled back to previous stable version." \
  "$(jq -cn --arg s "$STAGING_URL" '{stage:"production_rolled_back", staging_url:$s, required_action:"manual_review_code"}')"
exit 1
