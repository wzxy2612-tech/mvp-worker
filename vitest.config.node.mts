// vitest.config.node.mts ── V7 (mvp-worker) · node pool
// ═══════════════════════════════════════════════════════════════
// test/workflow-invariants.ts 的唯一栖身之地:它 readFileSync deploy.yml + package.json,
// 而 **Workers runtime 里没有文件系统**(cwd 是虚拟的 /bundle)。
//
// 文件名里**故意没有 `.spec.`** ⇒ vitest 的默认 include(`**/*.{test,spec}.*`)
// 在物理上匹配不到它 ⇒ Workers pool(vitest.config.mts)**够不着它**。
// 不靠配置,靠模式匹配。配置的语义我猜错过一次,模式匹配没有。
//
// 由 package.json 接上:
//   "test":          "vitest run && npm run test:workflow"
//   "test:workflow": "vitest run --config vitest.config.node.mts"
// ═══════════════════════════════════════════════════════════════
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/workflow-invariants.ts"],

    // ⛔ 显式 false(也是默认值,但这条不能靠默认)。
    //    include 哪天匹配不到东西时,必须**判红**,而不是「0 tests,全绿」。
    //    > **静默的空跑,和成功长得一模一样。**
    //    这是那 30 条不变量唯一的存活证明:它们要么跑、要么 npm test 红。没有第三种。
    passWithNoTests: false,
  },
});
