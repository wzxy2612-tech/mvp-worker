#!/bin/bash
# ==========================================================
# 共用函數庫 (Task 1)
#   - 一般日誌一律導向 stderr (>&2)
#   - 最終結果以純 JSON 輸出至 stdout
#   - Cloudflare 憑證統一由 load_cf_credentials 解析
# ==========================================================

# ---------- 日誌 ----------
log_info() {
    echo -e "\033[32m[INFO]\033[0m $1" >&2
}

log_error() {
    echo -e "\033[31m[ERROR]\033[0m $1" >&2
}

# ---------- JSON 字串轉義 ----------
# 只處理最常見的破壞字元：反斜線、雙引號、Tab；換行/Enter 轉成空白，
# 避免動態訊息破壞單行 JSON envelope。
json_escape() {
    printf '%s' "$1" \
      | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g' \
      | tr '\r\n' '  '
}

# ---------- 核心：輸出最終 JSON 至 stdout ----------
emit_json_result() {
    local success=$1        # "true" 或 "false"
    local message
    message=$(json_escape "$2")
    local data=${3:-"{}"}   # 額外 JSON 資料，需為合法 JSON（呼叫端負責）

    cat <<EOF
{
  "success": $success,
  "message": "$message",
  "data": $data,
  "timestamp": $(date +%s)
}
EOF
}

# ---------- Cloudflare 憑證載入 ----------
# 統一憑證來源，避免變數名不一致：
#   優先讀 wrangler 原生變數 CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN，
#   相容舊命名 CF_ACCOUNT_ID / CF_API_TOKEN。
# 解析成功後同時匯出兩套名稱：
#   CF_* 供本檔的 curl 呼叫；CLOUDFLARE_* 供 wrangler 自身認證。
# 回傳非 0 代表憑證缺失，由呼叫端決定是否中止。
load_cf_credentials() {
    # 自動載入同目錄下的 .env（請保持 LF 行尾，否則 token 會帶入 \r）
    if [ -f "${SCRIPT_DIR:-.}/.env" ]; then
        # shellcheck disable=SC1090
        source "${SCRIPT_DIR:-.}/.env"
    elif [ -f .env ]; then
        # shellcheck disable=SC1091
        source .env
    fi

    local acct token
    acct="${CLOUDFLARE_ACCOUNT_ID:-${CF_ACCOUNT_ID:-}}"
    token="${CLOUDFLARE_API_TOKEN:-${CF_API_TOKEN:-}}"

    if [ -z "$acct" ] || [ -z "$token" ]; then
        log_error "缺少 Cloudflare 憑證：請設定 CLOUDFLARE_ACCOUNT_ID 與 CLOUDFLARE_API_TOKEN（相容 CF_ACCOUNT_ID / CF_API_TOKEN）。"
        return 1
    fi

    export CF_ACCOUNT_ID="$acct"
    export CF_API_TOKEN="$token"
    export CLOUDFLARE_ACCOUNT_ID="$acct"
    export CLOUDFLARE_API_TOKEN="$token"
    return 0
}

# ---------- 可攜式 UTC 時間 ----------
# 產生「N 分鐘前」的 ISO8601 UTC，相容 GNU date（-d）與 BSD/macOS date（-v）
utc_minutes_ago() {
    local mins=$1
    date -u -d "${mins} minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
      || date -u -v-"${mins}"M +"%Y-%m-%dT%H:%M:%SZ"
}

utc_now() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}
