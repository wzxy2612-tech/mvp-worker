#!/usr/bin/env bash
set -euo pipefail
# scripts/rollback.sh ── V7
# ═══════════════════════════════════════════════════════════════
# 【V7 修的四件事】
#
# 1) 🔴 **「无历史版本」路径此前汇报成功。**
#    v6:找不到可回滚的版本 → `emit_json_result "skipped_no_history"` → **dispatch_ok=1**
#        → fold 成 **rolled_back**。
#    ⇒ **回滚根本没发生,而审计说「已回滚」,而且是硬终态、append-only、改不回来。**
#    ⇒ 这是最坏的一种谎:它发生在破窗通道上,发生在你最需要相信审计的那一刻。
#    ⇒ 同时,`rollback_rejected` 这个 action 在**五本账里都声明着**(state.ts 的 Action、
#      DeploymentState、CLOSING_ACTIONS、CALLBACK_ACTIONS、/audit 白名单)——
#      **从来没有任何代码写过它。** 现在它真的会被写。
#
#    判据是 **≥ 2**,不是 ≥ 1:`wrangler deployments list` **包含当前版本**。
#    只有 1 条 = 只有当前版本 = **没有可回退的目标**。
#
# 2) 🔴 **成功路径的静默洞。** v6:回滚成功 → send_audit_log 网络失败 → log_warn 吞掉 → exit 0。
#    ⇒ 生产**已经回滚了**,D1 里**零事件** ⇒ 5 分钟后 reaper 写 timed_out(软终态,看着像例行公事)。
#    现在:发射失败会 ::error:: 大声说出来(见 utils.sh 的政策说明)。
#
# 3) 🔴 **`${ROLLBACK_SOURCE:-auto_rollback}`。** 变量丢了 ⇒ **人工破窗被永久记录成机器自动回滚**。
#    审计面对「谁按的按钮」撒谎。全部改成 require_env 硬失败。
#
# 4) 删掉 BACKUP_CONFIG 那段:它把一个文件 cp 进 runner 的临时工作区,然后 log
#    「请另行部署」。**它什么都没做。** 一段读起来像在做事的死代码。
# ═══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./utils.sh
source "$SCRIPT_DIR/utils.sh"

# ROLLBACK_SOURCE 必须是 auto_rollback | manual_rollback —— 这两个是 state.ts 里的
# 独立 action,fold 出的硬终态相同(rolled_back),但**审计面靠它区分「谁按的按钮」**。
require_env TARGET_ENV CONTROLLER_URL TRIGGER_SECRET TRACE_ID ROLLBACK_SOURCE ROLLBACK_MESSAGE || exit 1

case "$ROLLBACK_SOURCE" in
  auto_rollback|manual_rollback) ;;
  *)
    log_error "ROLLBACK_SOURCE 非法:'${ROLLBACK_SOURCE}'(只能是 auto_rollback / manual_rollback)"
    echo "::error::ROLLBACK_SOURCE 非法。拒绝伪造一个 action。"
    exit 1
    ;;
esac

log_info "回滚目标环境:${TARGET_ENV} · 来源:${ROLLBACK_SOURCE}"

# ─────────────────────────────────────────────────────────────
# ① 虚无回滚保护 —— 在动手之前,先确认**有东西可以回退**。
#
# wrangler 4.110 的 `deployments list --json` 返回扁平数组(已在真机核实)。
# 数组**包含当前正在服役的版本** ⇒ 可回退 ⟺ length ≥ 2。
# ─────────────────────────────────────────────────────────────
set +e
LIST_JSON=$(npx wrangler deployments list --env "$TARGET_ENV" --json 2>/tmp/wr_list_err)
LIST_RC=$?
set -e

if [ "$LIST_RC" -ne 0 ]; then
  log_error "无法列出 ${TARGET_ENV} 的部署历史 (rc=${LIST_RC})"
  cat /tmp/wr_list_err >&2 || true
  # 查不到历史 ≠ 没有历史。**fail-closed**:不硬猜,发硬终态、判红、叫人。
  emit_event "$ROLLBACK_SOURCE" 0 "cannot list deployments for ${TARGET_ENV} (rc=${LIST_RC}) — refusing to guess" || true
  echo "::error title=回滚失败::无法读取部署历史。**没有执行回滚。**需要人工介入。"
  emit_json_result "failed" "deployments list failed" "$TARGET_ENV"
  exit 2
fi

COUNT=$(printf '%s' "$LIST_JSON" | jq 'length' 2>/dev/null || echo "0")
log_info "${TARGET_ENV} 部署历史条数:${COUNT}(含当前版本)"

if [ "$COUNT" -lt 2 ]; then
  log_error "没有可回退的目标:历史只有 ${COUNT} 条(含当前版本)"
  # ⚠️ 这里**不能**发 dispatch_ok=1。这不是「回滚成功」,是「回滚不可能」。
  #    rollback_rejected 是独立硬终态,语义是:**没有任何东西被回退,而且这是确定的。**
  emit_event rollback_rejected 0 "no rollback target: ${TARGET_ENV} has only ${COUNT} deployment(s)" || true
  echo "::error title=回滚被拒::${TARGET_ENV} 没有可回退的历史版本。**生产维持现状。**"
  emit_json_result "rejected" "no rollback target (${COUNT} deployments)" "$TARGET_ENV"
  exit 1   # 判红。这是唯一诚实的结局。
fi

# ─────────────────────────────────────────────────────────────
# ② 执行回滚
# ─────────────────────────────────────────────────────────────
log_info "执行:wrangler rollback --env ${TARGET_ENV}"

set +e
RB_OUTPUT=$(npx wrangler rollback --env "$TARGET_ENV" --message "$ROLLBACK_MESSAGE" --yes 2>&1)
RB_RC=$?
set -e

echo "$RB_OUTPUT"

if [ "$RB_RC" -ne 0 ]; then
  log_error "wrangler rollback 失败 (rc=${RB_RC})"
  # dispatch_ok=0 + auto/manual_rollback ⇒ fold 成 **rollback_failed**(硬终态)。
  # 语义:灾难态,需人工介入。这正是它该说的话。
  emit_event "$ROLLBACK_SOURCE" 0 "wrangler rollback FAILED (rc=${RB_RC}) on ${TARGET_ENV}" || true
  echo "::error title=回滚失败::wrangler rollback 返回 ${RB_RC}。**生产可能仍处于坏版本。**立即人工介入。"
  emit_json_result "failed" "wrangler rollback failed (rc=${RB_RC})" "$TARGET_ENV"
  exit 2
fi

# ─────────────────────────────────────────────────────────────
# ③ 回滚成功 → rolled_back(硬终态)
#
# 发射失败不判红:生产**确实已经回滚了**,把这个 job 判红只会让人以为回滚没成。
# 但 emit_event 会打 ::error:: 注解、且 reaper 的 5min deadline 会兜底成 timed_out。
# 审计降级会大声说出来,而不是安静地长得像成功。(政策见 utils.sh 顶部。)
# ─────────────────────────────────────────────────────────────
if emit_event "$ROLLBACK_SOURCE" 1 "${TARGET_ENV} rolled back OK — ${ROLLBACK_MESSAGE}"; then
  log_info "回滚完成,审计已落库。"
else
  log_error "回滚**成功了**,但审计事件没落库 —— 审计面会把这条 trace 记成 timed_out。"
fi

emit_json_result "rolled_back" "$ROLLBACK_MESSAGE" "$TARGET_ENV"
exit 0
