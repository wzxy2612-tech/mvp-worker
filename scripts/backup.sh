#!/bin/bash
# Task 3：組態與邊緣路由備份
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

BACKUP_DIR="./backups"
WRANGLER_CONF="wrangler.jsonc"

log_info "開始執行 Task 3: 組態與邊緣路由備份..."

# 1. 建立備份目錄
if [ ! -d "$BACKUP_DIR" ]; then
    log_info "建立備份目錄: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
fi

# 2. 自動偵測配置檔格式 (wrangler.jsonc / wrangler.toml)
if [ ! -f "$WRANGLER_CONF" ]; then
    if [ -f "wrangler.toml" ]; then
        WRANGLER_CONF="wrangler.toml"
    else
        log_error "找不到 wrangler.jsonc 或 wrangler.toml，請確認工作目錄！"
        emit_json_result "false" "Configuration file not found." "{}"
        exit 1
    fi
fi
CONF_EXT="${WRANGLER_CONF##*.}"

# 3. 追蹤識別碼：時間戳 + Git short hash
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null)

if [ -z "$GIT_HASH" ]; then
    log_info "未檢測到 Git 提交紀錄，僅使用時間戳記作為備份標記。"
    BACKUP_SUFFIX="${TIMESTAMP}"
else
    log_info "檢測到 Git 提交雜湊值: $GIT_HASH"
    BACKUP_SUFFIX="${TIMESTAMP}_${GIT_HASH}"
fi

# 4. 備份本地配置檔
BACKUP_CONF_NAME="wrangler_backup_${BACKUP_SUFFIX}.${CONF_EXT}"
cp "$WRANGLER_CONF" "$BACKUP_DIR/$BACKUP_CONF_NAME"
log_info "本地配置備份成功 -> $BACKUP_DIR/$BACKUP_CONF_NAME"

# 5. 匯出雲端 Workers 路由
#    Worker 路由是「zone 級」資源，正確端點為 /zones/{zone_id}/workers/routes。
#    workers.dev-only（未綁定自訂 zone）時沒有 zone 路由可備份 → 乾淨靜默跳過，不打 API。
ROUTES_BACKUP_NAME="routes_backup_${BACKUP_SUFFIX}.json"
ROUTES_STATUS="skipped_no_zone"

# Zone ID 為選用；相容 CLOUDFLARE_ZONE_ID / CF_ZONE_ID，並會嘗試載入同目錄 .env
if [ -f "${SCRIPT_DIR}/.env" ]; then
    # shellcheck disable=SC1090
    source "${SCRIPT_DIR}/.env"
elif [ -f .env ]; then
    # shellcheck disable=SC1091
    source .env
fi
CF_ZONE_ID="${CLOUDFLARE_ZONE_ID:-${CF_ZONE_ID:-}}"

if [ -z "$CF_ZONE_ID" ]; then
    log_info "未設定 CF_ZONE_ID（workers.dev-only 無 zone 路由），跳過路由備份。"
elif ! load_cf_credentials; then
    log_info "未提供 Cloudflare 憑證，跳過路由備份。"
    ROUTES_STATUS="skipped_no_credentials"
else
    log_info "正在向 Cloudflare 請求 zone 路由（zone: $CF_ZONE_ID）..."
    ROUTES_RESP=$(curl -s -w $'\n%{http_code}' -X GET \
      "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/workers/routes" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json")
    HTTP_CODE=$(printf '%s' "$ROUTES_RESP" | tail -n1)
    ROUTES_BODY=$(printf '%s' "$ROUTES_RESP" | sed '$d')

    if [ "$HTTP_CODE" = "200" ] \
       && [ "$(printf '%s' "$ROUTES_BODY" | jq -r '.success' 2>/dev/null)" = "true" ]; then
        printf '%s' "$ROUTES_BODY" | jq '.result' > "$BACKUP_DIR/$ROUTES_BACKUP_NAME"
        log_info "雲端路由備份成功 -> $BACKUP_DIR/$ROUTES_BACKUP_NAME"
        ROUTES_STATUS="exported"
    else
        log_error "路由獲取失敗 (HTTP ${HTTP_CODE:-N/A})，跳過路由備份。"
        ROUTES_STATUS="skipped_or_failed"
    fi
fi

# 6. 整合輸出
if [ "$ROUTES_STATUS" = "exported" ]; then
    REMOTE_ROUTES_JSON="\"$ROUTES_BACKUP_NAME\""
else
    REMOTE_ROUTES_JSON="null"
fi
if [ -z "$GIT_HASH" ]; then
    GIT_HASH_JSON="null"
else
    GIT_HASH_JSON="\"$GIT_HASH\""
fi

DATA_JSON=$(cat <<EOF
{
  "backup_directory": "$BACKUP_DIR",
  "local_config_backup": "$BACKUP_CONF_NAME",
  "config_format": "$CONF_EXT",
  "remote_routes_backup": $REMOTE_ROUTES_JSON,
  "git_hash": $GIT_HASH_JSON,
  "remote_routes_status": "$ROUTES_STATUS"
}
EOF
)

emit_json_result "true" "Configuration backup completed successfully." "$DATA_JSON"
