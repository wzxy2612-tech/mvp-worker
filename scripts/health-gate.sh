#!/usr/bin/env bash
set -euo pipefail
# scripts/health-gate.sh ── V7【更新版：增加 TERMINAL_DEPLOY 终点旗标】
# ═══════════════════════════════════════════════════════════════
# 只做一件事:对**已经部署上去的**目标做冒烟测试,并发出这条 trace 的进度/终态事件。
# ═══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./utils.sh
source "$SCRIPT_DIR/utils.sh"

require_env TARGET_ENV HEALTH_URL CONTROLLER_URL TRIGGER_SECRET TRACE_ID || exit 1

WARMUP_S="${WARMUP_S:-5}"
SMOKE_ROUNDS="${SMOKE_ROUNDS:-3}"
ROUND_GAP_S="${ROUND_GAP_S:-5}"
RETRIES_PER_ROUND="${RETRIES_PER_ROUND:-3}"
RETRY_GAP_S="${RETRY_GAP_S:-2}"

# ── 终局上报(幂等,trap 可能被触发两次)────────────────────────
_REPORTED=0
report_outcome() {
  local rc="$1"
  [ "$_REPORTED" -eq 1 ] && return 0
  _REPORTED=1

  if [ "$rc" -eq 0 ]; then
    # 【改动点】增加 TERMINAL_DEPLOY 旗标判断，保持脚本 drill-无关
    if [ "$TARGET_ENV" = "production" ] || [ "${TERMINAL_DEPLOY:-0}" = "1" ]; then
      # prod (或带有终点旗标的 drill) 的 deploy_ok = 硬终态 succeeded。这是整条 trace 的终点。
      emit_event deploy_ok 1 "${TARGET_ENV} health gate passed (${SMOKE_ROUNDS} rounds @ ${HEALTH_URL})" || true
    else
      # staging 通过 ⇒ gate_waiting(等人工审批)。不是终态。
      emit_event gate_passed 1 "${TARGET_ENV} deploy + health ok (${SMOKE_ROUNDS} rounds)" || true
    fi
  else
    # ⚠️ 取消路径必须**快**:GHA 的 SIGTERM → SIGKILL 宽限期约 7.5s。
    EMIT_MAX_TIME=3 EMIT_RETRIES=0 \
      emit_event deploy_fail 0 "${TARGET_ENV} health gate FAILED (rc=${rc}) @ ${HEALTH_URL}" || true
  fi
}

trap 'report_outcome $?' EXIT
trap 'report_outcome 143' INT TERM

# ── 冒烟 ────────────────────────────────────────────────────────
log_info "warmup ${WARMUP_S}s(冷启动)…"
sleep "$WARMUP_S"

probe_once() {
  curl -sS --max-time 8 -o /tmp/health_body.json -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || echo "000"
}

for round in $(seq 1 "$SMOKE_ROUNDS"); do
  ok=0
  for attempt in $(seq 1 "$RETRIES_PER_ROUND"); do
    code=$(probe_once)
    if [ "$code" = "200" ]; then
      log_info "round ${round}/${SMOKE_ROUNDS} attempt ${attempt}: HTTP 200 ✓ $(head -c 160 /tmp/health_body.json 2>/dev/null)"
      ok=1
      break
    fi
    log_warn "round ${round}/${SMOKE_ROUNDS} attempt ${attempt}: HTTP ${code} ✗"
    [ "$attempt" -lt "$RETRIES_PER_ROUND" ] && sleep "$RETRY_GAP_S"
  done

  if [ "$ok" -ne 1 ]; then
    log_error "健康门失败:${HEALTH_URL} 在第 ${round} 轮的 ${RETRIES_PER_ROUND} 次尝试全挂"
    echo "::error title=健康门失败::${TARGET_ENV} @ ${HEALTH_URL} 未通过冒烟测试。"
    emit_json_result "failed" "health gate failed at round ${round}" "$TARGET_ENV"
    exit 1   
  fi

  [ "$round" -lt "$SMOKE_ROUNDS" ] && sleep "$ROUND_GAP_S"
done

log_info "健康门通过:${TARGET_ENV} @ ${HEALTH_URL}"
emit_json_result "healthy" "health gate passed (${SMOKE_ROUNDS} rounds)" "$TARGET_ENV"
exit 0