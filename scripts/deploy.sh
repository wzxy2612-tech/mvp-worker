#!/usr/bin/env bash
set -euo pipefail
# scripts/deploy.sh ── V7
# ═══════════════════════════════════════════════════════════════
# 这个脚本只做一件事:**把代码传上去**。
#
# 不做:npm test(test job 已经跑过)、tsc(同上)、冒烟测试(在 health-gate.sh)、
#      发任何 /audit 事件(失败由 deploy.yml 的 `if: failure()` 网发 pipeline_failed)。
#
# ══ 为什么要拆成两个脚本 ——「步骤边界 = 部署边界」 ══
#
# v6 把 npm test + tsc + wrangler deploy + 冒烟测试**全塞进一个 step**(id=deploy_prod),
# 而 auto-rollback 的守卫是 `steps.deploy_prod.outcome == 'failure'`。
#
#   ⇒ prod runner 上 vitest 抖一下(网络、缓存、超时)→ deploy_prod 红
#     → **回滚一个健康的、根本没被动过的生产**
#     → 审计写 `rolled_back`。读起来完全合理。完全是假的。
#
#   ⇒ 就算删掉 npm test,`outcome=='failure'` 仍然分不清:
#       (a) wrangler deploy 上传失败 —— **什么都没部署**,回滚 = 虚无回滚
#       (b) 上传成功、健康门挂了 —— **新代码已在 prod 上**,必须回滚
#     这两件事在 v6 里是同一个信号。
#
# ⇒ V7:把「有没有东西被部署上去」变成一个**步骤边界**。
#     `outcome` 正是为表达步骤边界而生的 —— v6 的 bug 是边界画错了位置,不是信号选错了。
#
#     step deploy_prod (本文件)  失败 ⇒ 上传失败   ⇒ 死亡证明,**不回滚**
#     step health_prod (下一个)  失败 ⇒ 上传成功了 ⇒ **回滚**
#
#     这个做法不依赖任何我没验证过的 GHA 语义(比如「失败 step 的 $GITHUB_OUTPUT
#     还在不在」)。它只依赖 `steps.<id>.outcome`,而那个我们已经在生产上见过它工作。
# ═══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./utils.sh
source "$SCRIPT_DIR/utils.sh"

# ⛔ 没有 `${TARGET_ENV:-staging}`。变量丢了就硬失败。
#    v6 的 `${CLOUDFLARE_ENV:-staging}` 会:部到 dev,然后汇报「staging 的 gate_passed」。
require_env TARGET_ENV HEALTH_URL || exit 1

# 显式 --env,和 rollback.sh 用同一个机制。
#
# ⚠️ 刻意**不**用环境变量 CLOUDFLARE_ENV 那条隐式通道。
#    v6:deploy.sh 走隐式 CLOUDFLARE_ENV,rollback.sh 走显式 --env —— 两个机制。
#    wrangler 刚 4.108 → 4.110。隐式路径一旦回归:
#      deploy 打到顶层 mvp-worker-dev、打印 dev 的 URL、冒烟 dev、报 deploy_ok,
#      而 rollback.sh 依然正确地回滚 **production**。**部署到 dev,回滚 prod。**
#    现在 wrangler 只可能看见 --env。一个机制,不可能漂移。
log_info "wrangler deploy --env ${TARGET_ENV}"

set +e
DEPLOY_OUTPUT=$(npx wrangler deploy --env "$TARGET_ENV" 2>&1)
DEPLOY_RC=$?
set -e

echo "$DEPLOY_OUTPUT"

if [ "$DEPLOY_RC" -ne 0 ]; then
  log_error "wrangler deploy 失败 (rc=$DEPLOY_RC)"
  echo "::error title=上传失败::wrangler deploy 返回 ${DEPLOY_RC}。**没有任何代码被部署到 ${TARGET_ENV}**,因此绝不能回滚。"
  emit_json_result "failed" "wrangler deploy failed (rc=$DEPLOY_RC)" "$TARGET_ENV"
  exit 1
fi

# ─────────────────────────────────────────────────────────────
# 目标对账 —— 有两本账时,唯一安全的做法是**每次都大声 assert 它们一致**。
#
#   账本 A:HEALTH_URL,由 deploy.yml 按 env 显式声明(人的意图)
#   账本 B:wrangler 的输出(机器的真话)
#
# v6 是从 wrangler 输出里 grep URL:
#     grep -oE 'https://[a-zA-Z0-9._-]+\.workers\.dev' | head -n1
#     [ -z "$TARGET_URL" ] && grep -oE 'https://[a-zA-Z0-9._/-]+' | head -n1   ← 灾难
#
# 第二条正则匹配 wrangler 输出里的**任何** https URL —— warning 里的
# https://developers.cloudflare.com/... 、https://dash.cloudflare.com/... 。
# head -n1 抓到它 ⇒ 冒烟测试打 **Cloudflare 文档站** ⇒ 200 ⇒ 绿 ⇒ deploy_ok。
#
#   > 「live green ≠ deploy channel healthy」—— 你的公理,被 v6 写进了脚本里。
#
# 现在:HEALTH_URL 是唯一权威;wrangler 的输出只用来**证伪**它。
# URL 猜错 ⇒ 这里硬失败 ⇒ staging 红 ⇒ 什么都不会 ship。**fail-closed on 我的猜测。**
# ─────────────────────────────────────────────────────────────
HEALTH_HOST=$(printf '%s' "$HEALTH_URL" | sed -E 's#^https?://([^/]+).*#\1#')

if ! printf '%s' "$DEPLOY_OUTPUT" | grep -qF "$HEALTH_HOST"; then
  log_error "目标对账失败:wrangler 的输出里找不到 ${HEALTH_HOST}"
  echo "::error title=目标对账失败::HEALTH_URL 指向 ${HEALTH_HOST},但 wrangler 部署的不是它。可能部错环境了。拒绝对一个未知目标做冒烟测试。"
  emit_json_result "failed" "target mismatch: ${HEALTH_HOST} not in wrangler output" "$TARGET_ENV"
  exit 1
fi

log_info "目标对账通过:wrangler 输出中确认了 ${HEALTH_HOST}"
log_info "上传完成。健康门交给下一个 step(health-gate.sh)。"
emit_json_result "uploaded" "wrangler deploy ok; health gate pending" "$TARGET_ENV"
