// vitest.config.mts ── V7 (mvp-worker) · Workers pool
// ═══════════════════════════════════════════════════════════════
// 只跑需要 Workers runtime 的测试(test/index.spec.ts:业务 worker 的 /health 与 404)。
//
// ⚠️ 这里**没有 exclude**,而且不需要。
//    V7 初稿我在这里写了 `exclude: [..., "test/workflow.spec.ts"]` —— **不管用**。
//    cloudflareTest() 是个 plugin,它在内部建自己的 vitest project,
//    顶层的 test.exclude 传不进去。我猜了那套 0.18 插件 API 的语义,猜错了。
//
//    现在换成:那个文件叫 **workflow-invariants.ts**(名字里没有 `.spec.`)
//    ⇒ vitest 的默认 include `**/*.{test,spec}.*` 在**物理上**匹配不到它。
//    **不靠配置,靠模式匹配。** 配置语义我猜错过,模式匹配没有。
//
// ⚠️ 也**没有 include 白名单**。白名单的失效方式是**静默的**:新增一个 spec、
//    忘了加进数组 ⇒ 它不报错、不显示「0 tests」、**根本不会出现**,而 npm test 全绿。
//    > **那正是 workflow.spec.ts 的死法。别再造一个。**
// ═══════════════════════════════════════════════════════════════
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
    }),
  ],
});
