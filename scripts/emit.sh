#!/usr/bin/env bash
set -uo pipefail
# scripts/emit.sh ── V7【新文件】
# ═══════════════════════════════════════════════════════════════
# deploy.yml 里所有审计事件的**唯一**出口。
#
# 用法:bash scripts/emit.sh <action> <0|1> [detail]
#
# 为什么要有这个文件:
#   v6 里构造 /audit JSON 的地方有**三个**,各写各的转义:
#     · utils.sh 的 emit_event —— 手搓 printf 拼字符串
#     · utils.sh 的 json_escape —— sed 版
#     · deploy.yml 的死亡证明 step —— 内联 jq
#   三本账。detail 里出现一个引号 / 反斜杠 / 换行,就有一本会拼出坏 JSON ⇒
#   /audit 返 400 ⇒ **零事件,而流水线全绿**。
#
#   现在:deploy.yml **一行 JSON 都不构造**。所有事件都从这里走,
#   而这里只调 utils.sh 的 emit_event —— 全系统唯一的 jq -nc --arg。
#
# ⚠️ 刻意**不** `set -e`:发射失败**不该判红一个正在成功的 job**。
#    (审计发射失败的政策见 utils.sh 顶部。emit_event 会打 ::error:: 注解,
#     且 reaper 的 deadline 会把丢失终态的 trace 兜底成 timed_out。)
#    但**死亡证明 step 例外** —— 它本来就在一个已经红了的 job 里,退出码无关紧要。
# ═══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./utils.sh
source "$SCRIPT_DIR/utils.sh"

if [ "$#" -lt 2 ]; then
  echo "用法: emit.sh <action> <dispatch_ok 0|1> [detail]" >&2
  exit 64
fi

ACTION="$1"
OK="$2"
DETAIL="${3:-}"

case "$OK" in
  0|1) ;;
  *) log_error "dispatch_ok 只能是 0 或 1,收到 '$OK'"; exit 64 ;;
esac

emit_event "$ACTION" "$OK" "$DETAIL"
EMIT_RC=$?

# 出生事件(pipeline_started)是唯一一个「发不出去就必须判红」的:
# ADR 011 —— 审计面是 deploy 的**硬依赖**。发不出出生事件,这条 trace 在事件面上
# 根本不存在:不占锁、不被收割、不会有终局。那就别开始。
if [ "$ACTION" = "pipeline_started" ] && [ "$EMIT_RC" -ne 0 ]; then
  echo "::error title=出生事件未落库::审计面不可达。**拒绝在事件面之外启动一次部署。**"
  exit 1
fi

exit 0
