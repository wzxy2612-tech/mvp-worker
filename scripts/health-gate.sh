#!/usr/bin/env bash
set -euo pipefail
# scripts/health-gate.sh ── V7【新文件】
# ═══════════════════════════════════════════════════════════════
# 只做一件事:对**已经部署上去的**目标做冒烟测试,并发出这条 trace 的进度/终态事件。
#
# 这个 step 的 id(deploy.yml 里叫 health_stg / health_prod)是**回滚守卫的唯一锚点**:
#
#     if: failure() && steps.health_prod.outcome == 'failure'   → 回滚
#     if: failure() && steps.health_prod.outcome != 'failure'   → 死亡证明,不回滚
#
# 语义保证:能走到这个 step,就意味着 deploy.sh 的 `wrangler deploy` 已经返回 0
#          ⇒ **新代码确实在目标环境上** ⇒ 这里失败,回滚是有意义的、非虚无的。
#          deploy.sh 失败时这个 step 是 skipped ⇒ outcome != 'failure' ⇒ 不回滚。 ✅
#
# set -e + trap 的组合意味着:脚本里任何**意外**的失败(手滑、依赖缺失)也会走
# deploy_fail → 回滚。这是**对的**:prod 上的代码健康状况**未知** ⇒ 保守回滚。
# 未知 ≠ 健康。
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
    if [ "$TARGET_ENV" = "production" ]; then
      # prod 的 deploy_ok = 硬终态 succeeded。这是整条 trace 的终点。
      emit_event deploy_ok 1 "production health gate passed (${SMOKE_ROUNDS} rounds @ ${HEALTH_URL})" || true
    else
      # staging 通过 ⇒ gate_waiting(等人工审批)。不是终态。
      emit_event gate_passed 1 "${TARGET_ENV} deploy + health ok (${SMOKE_ROUNDS} rounds)" || true
    fi
  else
    # ⚠️ 取消路径必须**快**:GHA 的 SIGTERM → SIGKILL 宽限期约 7.5s。
    #    v6 用 --max-time 10 + 重试 ⇒ curl 还没超时就被 SIGKILL ⇒ 事件发不出去。
    EMIT_MAX_TIME=3 EMIT_RETRIES=0 \
      emit_event deploy_fail 0 "${TARGET_ENV} health gate FAILED (rc=${rc}) @ ${HEALTH_URL}" || true
  fi
}

# EXIT 覆盖正常退出与 set -e;INT/TERM 覆盖取消。_REPORTED 保证只发一次。
# (v6 只 trap EXIT ⇒ SIGTERM 直接终止、EXIT trap 未必跑到。)
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
    exit 1   # → trap → deploy_fail → (prod) auto-rollback step 接手
  fi

  [ "$round" -lt "$SMOKE_ROUNDS" ] && sleep "$ROUND_GAP_S"
done

log_info "健康门通过:${TARGET_ENV} @ ${HEALTH_URL}"
emit_json_result "healthy" "health gate passed (${SMOKE_ROUNDS} rounds)" "$TARGET_ENV"
exit 0   # → trap → deploy_ok(prod) / gate_passed(staging)
