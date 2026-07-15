#!/usr/bin/env bash
# scripts/utils.sh ── V7
# ═══════════════════════════════════════════════════════════════
# 全系统唯一的审计发射器 + 硬性环境变量校验。
#
# 【V7 修的三件事】
#
# 1) **三套 JSON 转义器 → 一套。**
#    v6:deploy.sh 手搓 printf、utils.sh 的 sed 版 json_escape、deploy.yml 里的 jq。
#    三本账,各自处理引号/反斜杠/换行/控制字符。一个 detail 里带个引号,
#    就能让 /audit 收到坏 JSON → 400 → **零事件,而流水线全绿**。
#    现在:只有 `jq -nc --arg`。sed 版 json_escape 已删除。
#
# 2) **不再对 HTTP 状态码瞎。**
#    v6 的 emit_event:`curl ... >/dev/null 2>&1` —— 连状态码都没在看。
#    v6 的 send_audit_log:打印 http_code 然后**不分支**。
#    /audit 返 400(action 非法)或 500(D1 写失败)时,流水线全绿、零事件。
#    「HTTP 200 ≠ written」是你的公理,而那两个发射器连 200 都没在看。
#
# 3) **`${VAR:-default}` 全家清除。**
#    `${ROLLBACK_SOURCE:-auto_rollback}` ⇒ 手动回滚被永久记成机器自动。
#    `${CLOUDFLARE_ENV:-staging}`        ⇒ 部到 dev,却汇报这是 staging 的 gate_passed。
#    > **bash 的 `:-` 就是 TS 的 `?? 'default'`:静默伪造一个可信的、错误的终局。**
#    变量丢了必须硬失败。require_env 就是那个硬失败。
#
# 【发射失败的政策 —— 刻意不对称,理由如下】
#   ADR 011:审计面是 deploy 的**硬依赖**,preflight 拿不到 /audit 直接 exit 1。
#   ⇒ 到了部署阶段,/audit 几分钟前还是活的,只剩瞬时抖动这一种可能。
#   在**终点**把审计发射失败升级成任务失败,只会让事情更糟:
#     · prod 健康、但 deploy_ok 没发出去 → 若因此判红 → **回滚一个健康的生产**。
#     · 若改成走死亡证明 → 审计写 pipeline_failed(「什么都没部署」)→ **纯撒谎**。
#   ⇒ 终点侧:激进重试 + ::error:: 注解 + 返回非 0 让调用方知情,但**不因此判红**。
#     丢失的终态由 reaper 的 deadline 兜底(timed_out=10 已真机验证这条路是活的)。
#   审计面降级会**大声说出来**,而不是安静地长得像成功。
# ═══════════════════════════════════════════════════════════════

log_info()  { echo "[INFO]  $(date -u '+%H:%M:%S') $*" >&2; }
log_warn()  { echo "[WARN]  $(date -u '+%H:%M:%S') $*" >&2; }
log_error() { echo "[ERROR] $(date -u '+%H:%M:%S') $*" >&2; }

utc_now()   { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# ── 硬性环境变量校验 ────────────────────────────────────────────
# 用法:require_env TARGET_ENV HEALTH_URL || exit 1
require_env() {
  local missing="" v
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then missing="$missing $v"; fi
  done
  if [ -n "$missing" ]; then
    log_error "缺少必需的环境变量:$missing"
    echo "::error::缺少必需的环境变量:$missing —— 拒绝用默认值伪造一个可信的错误终局。"
    return 1
  fi
  return 0
}

# ── 唯一的审计发射器 ────────────────────────────────────────────
# emit_event <action> <dispatch_ok 0|1> [detail]
#
# 返回 0 = /audit 确认收下(2xx);非 0 = **没收下**。调用方必须处理返回值。
#
# 可调(给取消路径用):
#   EMIT_MAX_TIME (默认 5)  —— ⚠️ 必须 < GHA 取消宽限期(约 7.5s SIGKILL)。
#                              v6 用 --max-time 10 ⇒ 取消时 curl 还没超时就被 SIGKILL,
#                              **Drill B 想观测的那条 deploy_fail 可能根本发不出去。**
#   EMIT_RETRIES  (默认 3)
emit_event() {
  local action="$1" ok="$2" detail="${3:-}"
  local max_time="${EMIT_MAX_TIME:-5}" retries="${EMIT_RETRIES:-3}"

  require_env CONTROLLER_URL TRIGGER_SECRET TRACE_ID || return 1

  local body
  body=$(jq -nc \
    --arg  t "$TRACE_ID" \
    --arg  a "$action" \
    --argjson k "$ok" \
    --arg  d "$detail" \
    '{trace_id: $t, action: $a, dispatch_ok: $k, detail: $d}') || {
      log_error "jq 构造 /audit 请求体失败"
      return 1
    }

  local resp_file code
  resp_file=$(mktemp)
  code=$(curl -sS \
           --max-time "$max_time" \
           --retry "$retries" --retry-delay 1 --retry-all-errors \
           -o "$resp_file" -w '%{http_code}' \
           -X POST "${CONTROLLER_URL%/}/audit" \
           -H "X-Trigger-Secret: $TRIGGER_SECRET" \
           -H "Content-Type: application/json" \
           -d "$body" 2>/dev/null) || code="000"

  case "$code" in
    2*)
      # /audit 会回 {"data":{"written":true|false}} —— written=false 表示幂等去重命中,
      # 那是**正确**的(重复事件),不是错误。
      log_info "audit ✓ [$action ok=$ok] HTTP $code $(head -c 200 "$resp_file" 2>/dev/null)"
      rm -f "$resp_file"
      return 0
      ;;
    *)
      log_error "audit ✗ [$action ok=$ok] HTTP $code —— **事件没落库**"
      head -c 500 "$resp_file" >&2 2>/dev/null || true
      echo "" >&2
      echo "::error title=审计面降级::事件 [$action] 未写入 D1 (HTTP $code)。此 trace 的终局将由 reaper deadline 兜底为 timed_out。"
      rm -f "$resp_file"
      return 1
      ;;
  esac
}

# ── stdout 契约(给 GHA 的 step summary / 人类阅读)────────────────
# 只写 stdout;所有 log_* 走 stderr ⇒ 两者不会互相污染。
emit_json_result() {
  local status="$1" message="$2" target="${3:-}"
  jq -nc \
    --arg s "$status" \
    --arg m "$message" \
    --arg t "$target" \
    --arg ts "$(utc_now)" \
    '{status: $s, message: $m, target: $t, timestamp: $ts}'
}
