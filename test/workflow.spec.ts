// test/workflow.spec.ts
// ─────────────────────────────────────────────────────────────
// deploy.yml 的结构不变量 —— 用**真正的 YAML 解析器**,不是 grep。
//
// 为什么从 verify-system.sh 搬到这里:
//   grep 版本在两轮内误报了两次(一次 grep 步骤名,一次 grep 缩进)。
//   **用正则去验一个结构化文档 = 把 YAML 的结构重新编码一遍 = 第二本账。**
//   它会和 GitHub 真正的解析器漂移,而且漂移的方式是「假警报」——
//   一个假警报恰好落在合理格子里,就会送你去追一个不存在的 bug。
//
// 搬进 npm test 的额外收益:**每次 push 自动跑**,不用等谁想起来执行那个脚本。
//
// 依赖:npm i -D yaml
// ─────────────────────────────────────────────────────────────
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { parse } from "yaml";

interface Step {
  name?: string;
  id?: string;
  if?: string;
  run?: string;
  uses?: string;
}
interface Job {
  needs?: string | string[];
  environment?: string;
  concurrency?: { group?: string; "cancel-in-progress"?: boolean };
  env?: Record<string, string>;
  steps: Step[];
}
interface Workflow {
  concurrency?: unknown;
  jobs: Record<string, Job>;
}

const wf = parse(readFileSync(".github/workflows/deploy.yml", "utf8")) as Workflow;
const jobs = wf.jobs;
const DEPLOY_CHAIN = ["preflight", "test", "deploy-staging", "deploy-production"] as const;

describe("deploy.yml 结构不变量", () => {
  it("五个 job 齐全", () => {
    expect(Object.keys(jobs).sort()).toEqual(
      ["deploy-production", "deploy-staging", "preflight", "rollback", "test"].sort(),
    );
  });

  // ── ADR 003:破窗通道 ──
  it("⛔ 无 workflow 级 concurrency —— 它会把 rollback 拉进同组排队,拆掉抢占", () => {
    expect(wf.concurrency).toBeUndefined();
  });

  it("⛔ rollback 无 needs —— 结构性豁免,不靠 if: 条件判断", () => {
    // 靠**结构**(不在 needs 链上)而不是靠**判断**。条件守卫最容易被后续修改
    // 悄悄写错,而且没有任何测试会提醒你。
    // 它同时保证:controller 挂掉时紧急回滚仍能跑(preflight 会失败,但 rollback 不经过它)。
    expect(jobs.rollback.needs).toBeUndefined();
  });

  it("production-deploy 组恰好 = {deploy-production, rollback}", () => {
    const members = Object.entries(jobs)
      .filter(([, j]) => j.concurrency?.group === "production-deploy")
      .map(([n]) => n)
      .sort();
    expect(members).toEqual(["deploy-production", "rollback"]);
  });

  it("非对称锁:只有 rollback 抢占(cancel-in-progress: true)", () => {
    const preemptors = Object.entries(jobs)
      .filter(([, j]) => j.concurrency?.["cancel-in-progress"] === true)
      .map(([n]) => n);
    expect(preemptors).toEqual(["rollback"]);
    expect(jobs["deploy-production"].concurrency?.["cancel-in-progress"]).toBe(false);
  });

  it("staging 独立并发组 —— rollback 只动 prod,不该抢占 staging", () => {
    expect(jobs["deploy-staging"].concurrency?.group).toBe("staging-deploy");
  });

  // ── ADR 012:preflight 顺序 ──
  it("preflight:出生证明在锁裁决之前(倒过来 = 每次 /deploy 都自锁)", () => {
    const body = jobs.preflight.steps.map((s) => s.run ?? "").join("\n");
    const birth = body.indexOf("pipeline_started");
    const lock = body.indexOf("/lock");
    expect(birth).toBeGreaterThanOrEqual(0);
    expect(lock).toBeGreaterThanOrEqual(0);
    expect(birth).toBeLessThan(lock);
  });

  // ── ADR 010:死亡证明必须由 if: failure() 兜住 ──
  it.each(DEPLOY_CHAIN)("%s 有 if: failure() 兜底的死亡证明", (name) => {
    // ⚠️ 光「文件里出现过 pipeline_failed」不算数。
    //    写在 bash 的 if 分支里 = 靠**枚举**失败模式 = 迟早漏一个。
    //    真实案例:出生已落库 → 查锁超时 → exit 1 → 没有死亡证明
    //             → trace 卡 in_flight 15 分钟 → **锁的 fail-closed 路径自己把环境锁死了。**
    const net = jobs[name].steps.filter(
      (s) => s.if?.includes("failure()") && (s.run ?? "").includes("pipeline_failed"),
    );
    expect(net.length).toBeGreaterThanOrEqual(1);
  });

  // ── 虚无回滚保护 ──
  it("auto-rollback 被 steps.deploy_prod.outcome 守卫", () => {
    // 只写 if: failure() → **任何**先前步骤失败都触发回滚,包括 npm ci。
    // 一次 registry 打嗝会把生产回滚掉,而根本没部署过任何东西。
    const steps = jobs["deploy-production"].steps;
    expect(steps.find((s) => s.id === "deploy_prod")).toBeDefined();

    const ar = steps.find((s) => (s.run ?? "").includes("rollback.sh"));
    expect(ar, "找不到 auto-rollback 步骤").toBeDefined();
    expect(ar!.if).toContain("steps.deploy_prod.outcome == 'failure'");
  });

  it("auto-rollback 是独立 step,不是 bash 的 ||", () => {
    // GitHub 能在取消时重新求值 step 的 if:,**重新求值不了 bash 的 ||** ——
    // 被抢占的 deploy 会自己再启一个竞争回滚,和 manual_rollback 同时打同一个 worker。
    const all = Object.values(jobs)
      .flatMap((j) => j.steps)
      .map((s) => s.run ?? "")
      .join("\n");
    expect(all).not.toMatch(/deploy\.sh\s*\|\|/);
  });

  it("死于 deploy 之前 ⇒ 不回滚、但必须闭环(两个条件互斥且穷尽)", () => {
    const steps = jobs["deploy-production"].steps;
    const ar = steps.find((s) => s.if?.includes("steps.deploy_prod.outcome == 'failure'"));
    const pf = steps.find((s) => s.if?.includes("steps.deploy_prod.outcome != 'failure'"));
    expect(ar, "缺 auto-rollback").toBeDefined();
    expect(pf, "缺 pre-deploy 死亡证明 —— 加了守卫却不发它 = 用可见 bug 换 7 天 ghost").toBeDefined();
  });

  // ── TRACE_ID 一致性 ──
  it("deploy 链上 TRACE_ID 表达式逐字一致", () => {
    // 分岔过一次:preflight 曾用 bash if/else 自己算,在「UI dispatch 不填 trace_id」时
    // 算出空串,和其他 job 的 push-<run_id> 对不上 → 事件写进两条不同的 trace。
    const exprs = new Set(DEPLOY_CHAIN.map((j) => jobs[j].env?.TRACE_ID));
    expect(exprs.size, `分岔:${[...exprs].join(" | ")}`).toBe(1);
    expect([...exprs][0]).toContain("push-");
  });

  it("rollback 的 TRACE_ID 用 rollback- 前缀(与 deploy 链区分)", () => {
    expect(jobs.rollback.env?.TRACE_ID).toContain("rollback-");
  });

  // ── environment ──
  it("环境分配正确", () => {
    expect(jobs["deploy-staging"].environment).toBe("staging");
    expect(jobs["deploy-production"].environment).toBe("production");
    // ⛔ production-rollback **绝不能**配 required_reviewers —— 那是 GitHub 仓库设置,
    //    代码里看不见。加一个 reviewer,破窗通道就被静默焊死。
    //    verify-system.sh 的 D 段用 GitHub API 查它。
    expect(jobs.rollback.environment).toBe("production-rollback");
  });
});
