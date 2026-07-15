// test/workflow-invariants.ts ── V7
// ═══════════════════════════════════════════════════════════════
// ⚠️⚠️ 文件名里**故意没有 `.spec.`** —— 别改回去。
//
//   Vitest 的默认 include 是 `**/*.{test,spec}.?(c|m)[jt]s?(x)`。
//   叫 workflow.spec.ts 的时候,它被 **Workers pool** 抓走了(vitest.config.mts),
//   而这里的 readFileSync 在 Workers runtime 里必炸 —— cwd 是虚拟的 `/bundle`:
//
//       ❯ test/workflow.spec.ts (0 test)
//       Error: no such file or directory, readAll '/bundle/.github/workflows/deploy.yml'
//
//   ⇒ `vitest run` 非零 ⇒ package.json 的 `vitest run && npm run test:workflow` **短路**
//   ⇒ **test:workflow 从头到尾没跑** ⇒ 下面这 30 条不变量,一条都没执行。
//
//   在 vitest.config.mts 里写 exclude **不管用**:cloudflareTest() 是个 plugin,
//   它在内部建自己的 project,顶层 test.exclude 传不进去。
//   ⇒ 所以不靠配置,靠**文件名**。默认 include 在物理上匹配不到 `workflow-invariants.ts`。
//   ⇒ 它只由 vitest.config.node.mts 显式 include(node pool,有真文件系统)。
//
//   改回 *.spec.ts ⇒ Workers pool 立刻又抓走它 ⇒ 立刻炸红。**吵,但至少不是静默的。**
// ═══════════════════════════════════════════════════════════════
// deploy.yml 的**结构不变量**。用真 YAML 解析器,不 grep。
//
// ⚠️ 这个文件在 v6 里**从未在 CI 里跑过。**
//    package.json:  "test": "vitest"                                   ← Workers pool,无 fs
//                   "test:workflow": "vitest run --config ...node.mts" ← node pool,有 fs
//    而 deploy.yml 的 test job 只跑 `npm test`。readFileSync 需要 fs ⇒
//    这些不变量只在有人**手动**敲 `npm run test:workflow` 时才跑。
//    它的文件头写着「搬进 npm test 的额外收益:每次 push 自动跑」—— **那句话没成立。**
//
//    而这些不变量里就包括「auto-rollback 必须带守卫」——
//    **虚无回滚的唯一看门人。看门人自己没上班。**
//
//    V7:package.json 的 "test" 现在链了 test:workflow。
// ═══════════════════════════════════════════════════════════════
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { parse } from "yaml";

interface Step {
  name?: string;
  id?: string;
  if?: string;
  run?: string;
  uses?: string;
  env?: Record<string, string>;
}
interface Job {
  if?: string;
  steps?: Step[];
  environment?: string;
  concurrency?: { group?: string; "cancel-in-progress"?: boolean };
  needs?: string | string[];
  env?: Record<string, string>;
}
interface Workflow {
  env?: Record<string, string>;
  jobs: Record<string, Job>;
}

const RAW = readFileSync(".github/workflows/deploy.yml", "utf8");
const WF = parse(RAW) as Workflow;

const job = (n: string): Job => {
  const j = WF.jobs[n];
  if (!j) throw new Error(`deploy.yml 里没有 job '${n}'`);
  return j;
};
const steps = (n: string): Step[] => job(n).steps ?? [];
const stepById = (n: string, id: string): Step | undefined => steps(n).find((s) => s.id === id);
const stepsWithRun = (n: string, needle: string): Step[] =>
  steps(n).filter((s) => (s.run ?? "").includes(needle));

// ═════════════════════════════════════════════════════════════════
describe("① 步骤边界 = 部署边界 —— 虚无回滚的引信", () => {
  // 这一组是整个文件的核心。v6 的 bug 是**步骤边界画错了位置**:
  // 「有没有东西被部署上去」这个事实,被塞进了一个同时包含 npm test 的 step 的 outcome 里。
  it("deploy-production 必须同时有 deploy_prod(上传)和 health_prod(健康门)两个 step", () => {
    expect(stepById("deploy-production", "deploy_prod"), "缺 id=deploy_prod").toBeDefined();
    expect(stepById("deploy-production", "health_prod"), "缺 id=health_prod").toBeDefined();
  });

  it("deploy_prod 只跑 deploy.sh;health_prod 只跑 health-gate.sh", () => {
    expect(stepById("deploy-production", "deploy_prod")!.run).toContain("scripts/deploy.sh");
    expect(stepById("deploy-production", "health_prod")!.run).toContain("scripts/health-gate.sh");
  });

  it("上传必须排在健康门之前(否则健康门测的是旧代码 —— 一个永远绿的门)", () => {
    const list = steps("deploy-production");
    const iUp = list.findIndex((s) => s.id === "deploy_prod");
    const iHg = list.findIndex((s) => s.id === "health_prod");
    expect(iUp).toBeGreaterThanOrEqual(0);
    expect(iHg).toBeGreaterThan(iUp);
  });

  it("自动回滚**必须**由 health_prod.outcome == 'failure' 守卫", () => {
    const rb = stepsWithRun("deploy-production", "scripts/rollback.sh");
    expect(rb, "deploy-production 里没有回滚 step").toHaveLength(1);
    const guard = rb[0].if ?? "";
    expect(guard, "回滚没有 if 守卫 —— 这就是虚无回滚").toContain("failure()");
    expect(guard).toContain("steps.health_prod.outcome");
    expect(guard).toContain("== 'failure'");
  });

  it("⛔ 任何守卫里都不许再出现 steps.deploy_prod.outcome", () => {
    // 这是骗了我们的那个信号。它把「什么都没部署」和「部署了但坏了」算成同一件事。
    // v6:npm ci 挂 → deploy_prod.outcome == 'failure' → **回滚一个从未被动过的生产**。
    for (const [name, j] of Object.entries(WF.jobs)) {
      for (const s of j.steps ?? []) {
        expect(
          s.if ?? "",
          `job=${name} step=${s.name ?? s.id} 的守卫里出现了 steps.deploy_prod.outcome`,
        ).not.toContain("deploy_prod.outcome");
      }
    }
  });

  it("死亡证明与自动回滚在 failure() 上互斥且穷尽", () => {
    const rb = stepsWithRun("deploy-production", "scripts/rollback.sh")[0];
    const dc = steps("deploy-production").find(
      (s) => (s.run ?? "").includes("pipeline_failed") && (s.if ?? "").includes("failure()"),
    );
    expect(dc, "deploy-production 缺 pipeline_failed 死亡证明").toBeDefined();
    expect(rb.if).toContain("steps.health_prod.outcome == 'failure'");
    expect(dc!.if).toContain("steps.health_prod.outcome != 'failure'");
  });
});

// ═════════════════════════════════════════════════════════════════
describe("② Self-check —— 僵尸部署 / Re-run / superseded", () => {
  for (const j of ["deploy-staging", "deploy-production"]) {
    it(`${j} 的第一个 step 必须是 Self-check(GET /lock)`, () => {
      const first = steps(j)[0];
      expect(first?.run ?? "", `${j} 的首个 step 不是 Self-check`).toContain("/lock?trace_id=");
    });

    it(`${j} 的 Self-check 必须 fail-closed(非 200 一律中止)`, () => {
      const run = steps(j)[0].run ?? "";
      expect(run).toContain("409");
      // 「查不到锁 ≠ 没有锁」:控制面 500 / 超时,绝不能当成「没锁,放行」。
      expect(run).toMatch(/\[\s*"\$code"\s*=\s*"200"\s*\]/);
    });

    it(`${j} 的 Self-check 必须早于任何 wrangler 操作`, () => {
      const list = steps(j);
      const iSelf = list.findIndex((s) => (s.run ?? "").includes("/lock?trace_id="));
      const iDeploy = list.findIndex((s) => (s.run ?? "").includes("scripts/deploy.sh"));
      expect(iSelf).toBeGreaterThanOrEqual(0);
      expect(iDeploy).toBeGreaterThan(iSelf);
    });
  }
});

// ═════════════════════════════════════════════════════════════════
describe("③ 四张死亡证明 + 回滚 job 的网(V7 新增)", () => {
  it("preflight / test / deploy-staging / deploy-production 各有 pipeline_failed 网", () => {
    for (const j of ["preflight", "test", "deploy-staging", "deploy-production"]) {
      const dc = steps(j).find(
        (s) => (s.run ?? "").includes("pipeline_failed") && (s.if ?? "").includes("failure()"),
      );
      expect(dc, `job ${j} 缺 pipeline_failed 死亡证明 ⇒ 静默死亡 ⇒ 环境锁泄漏`).toBeDefined();
    }
  });

  it("每个 job 都有 cancelled() 网", () => {
    for (const j of Object.keys(WF.jobs)) {
      const c = steps(j).find((s) => (s.if ?? "").includes("cancelled()"));
      expect(c, `job ${j} 缺 cancelled() 网`).toBeDefined();
      expect(c!.run ?? "").toContain("cancelled");
    }
  });

  it("【V7】rollback job 必须有 if: failure() 网,且发 manual_rollback ok=0", () => {
    // v6:这里什么网都没有。checkout / npm ci 挂 ⇒ 零事件 ⇒ in_flight_rollback → timed_out
    // (**软**终态,读起来像例行公事)。整个系统最坏的失败伪装成最平常的样子。
    const net = steps("rollback").find(
      (s) => (s.if ?? "").trim() === "failure()" && (s.run ?? "").includes("manual_rollback"),
    );
    expect(net, "rollback job 缺 if: failure() 死亡证明").toBeDefined();
    // manual_rollback + ok=0 ⇒ fold 成 rollback_failed(硬终态)
    expect(net!.run).toMatch(/manual_rollback\s+0/);
  });

  it("取消路径的发射必须快过 GHA 的 SIGKILL 宽限期(~7.5s)", () => {
    // v6 用 --max-time 10 ⇒ curl 还没超时就被 SIGKILL ⇒ 事件根本发不出去。
    for (const j of Object.keys(WF.jobs)) {
      const c = steps(j).find((s) => (s.if ?? "").includes("cancelled()"));
      const t = Number(c?.env?.EMIT_MAX_TIME ?? "999");
      expect(t, `job ${j} 的 cancelled 网 EMIT_MAX_TIME=${t},必须 < 7`).toBeLessThan(7);
    }
  });
});

// ═════════════════════════════════════════════════════════════════
describe("④ 单一账本 —— 变量、URL、机制", () => {
  it("TRACE_ID 只在**工作流顶层**声明一次,任何 job/step 都不许重新声明", () => {
    expect(WF.env?.TRACE_ID, "顶层缺 TRACE_ID").toBeDefined();
    for (const [name, j] of Object.entries(WF.jobs)) {
      expect(Object.keys(j.env ?? {}), `job ${name} 重新声明了 TRACE_ID`).not.toContain("TRACE_ID");
      for (const s of j.steps ?? []) {
        expect(
          Object.keys(s.env ?? {}),
          `job ${name} 的 step "${s.name ?? s.id}" 重新声明了 TRACE_ID`,
        ).not.toContain("TRACE_ID");
      }
    }
  });

  it("⛔ 任何地方都不许设 CLOUDFLARE_ENV —— 只走显式 --env,一个机制", () => {
    // v6:deploy.sh 走隐式 CLOUDFLARE_ENV,rollback.sh 走显式 --env。两个机制。
    // 隐式那条一旦回归(wrangler 刚 4.108→4.110):**部署到 dev,回滚 prod。**
    const bad: string[] = [];
    for (const [name, j] of Object.entries(WF.jobs)) {
      if ("CLOUDFLARE_ENV" in (j.env ?? {})) bad.push(`job:${name}`);
      for (const s of j.steps ?? []) {
        if ("CLOUDFLARE_ENV" in (s.env ?? {})) bad.push(`step:${name}/${s.name ?? s.id}`);
      }
    }
    if ("CLOUDFLARE_ENV" in (WF.env ?? {})) bad.push("workflow-level");
    expect(bad, `CLOUDFLARE_ENV 出现在:${bad.join(", ")}`).toHaveLength(0);
  });

  it("两个部署 job 都必须显式声明 TARGET_ENV 和 HEALTH_URL", () => {
    // HEALTH_URL 显式化,是为了让 deploy.sh 能拿它跟 wrangler 的输出**对账**。
    // v6 从 wrangler 输出里 grep URL,第二条正则会匹配到 warning 里的
    // https://developers.cloudflare.com/... ⇒ 冒烟测试打 Cloudflare 文档站 ⇒ 200 ⇒ 绿。
    const expected: Record<string, string> = {
      "deploy-staging": "staging",
      "deploy-production": "production",
    };
    for (const [j, env] of Object.entries(expected)) {
      expect(job(j).env?.TARGET_ENV, `${j} 缺 TARGET_ENV`).toBe(env);
      const url = job(j).env?.HEALTH_URL ?? "";
      expect(url, `${j} 缺 HEALTH_URL`).toMatch(/^https:\/\/\S+\/health$/);
      expect(url, `${j} 的 HEALTH_URL 里没有 '${env}'`).toContain(env);
    }
  });

  it("⛔ deploy.yml 里一行 JSON 都不许构造 —— 全部走 scripts/emit.sh", () => {
    // 三套 JSON 转义器(手搓 printf / sed / 内联 jq)⇒ 一套。
    for (const [name, j] of Object.entries(WF.jobs)) {
      for (const s of j.steps ?? []) {
        const run = s.run ?? "";
        if (run.includes("/audit")) {
          expect.fail(`job ${name} 的 step "${s.name ?? s.id}" 直接打了 /audit。请走 scripts/emit.sh。`);
        }
        if (run.includes("jq -n")) {
          expect.fail(`job ${name} 的 step "${s.name ?? s.id}" 在 YAML 里构造 JSON。请走 scripts/emit.sh。`);
        }
      }
    }
  });
});

// ═════════════════════════════════════════════════════════════════
describe("⑤ 出生 / 锁 / 破窗", () => {
  it("preflight:出生事件必须**先于**锁检查(ADR 012)", () => {
    // /lock 的 seq-min 裁决要拿 MIN(id) 当 callerSeq。出生行还没落库 ⇒ callerSeq = Infinity
    // ⇒ **任何**活跃 trace 都比我老 ⇒ 我永远输 ⇒ 锁永久拒绝所有人。
    const list = steps("preflight");
    const iBirth = list.findIndex((s) => (s.run ?? "").includes("pipeline_started"));
    const iLock = list.findIndex((s) => (s.run ?? "").includes("/lock?trace_id="));
    expect(iBirth, "preflight 缺出生事件").toBeGreaterThanOrEqual(0);
    expect(iLock, "preflight 缺锁检查").toBeGreaterThan(iBirth);
  });

  it("rollback job 必须有确认字面量,且不走 preflight 的锁", () => {
    const guard = job("rollback").if ?? "";
    expect(guard).toContain("YES_ROLLBACK");
    expect(job("rollback").needs, "破窗通道不能 needs preflight —— 锁挡住破窗 = 破窗不存在").toBeUndefined();
  });

  it("rollback 与 deploy-production 同并发组且 cancel-in-progress —— 抢占正在跑的 prod 部署", () => {
    expect(job("rollback").concurrency?.group).toBe(job("deploy-production").concurrency?.group);
    expect(job("rollback").concurrency?.["cancel-in-progress"]).toBe(true);
  });

  it("🔒 非对称锁:全文件**只有 rollback** 一个 cancel-in-progress: true", () => {
    // V7 初稿我把 deploy-production 也设成了 true —— 被 verify-system.sh 的 A4 抓到。
    //
    // cancel-in-progress: true = 「后来者杀死先到者」= **last-wins**。
    // 而事件面的 ADR 012 是 **seq-min first-wins**。
    // 两个仲裁机制,政策完全相反 ⇒ **本项目每一个严重 bug 的形状。**
    //
    // 破窗是**单向**的:rollback 杀 deploy,deploy 之间只排队(排到队也会被 Self-check 挡)。
    const preemptors = Object.entries(WF.jobs)
      .filter(([, j]) => j.concurrency?.["cancel-in-progress"] === true)
      .map(([n]) => n);
    expect(preemptors, `只有 rollback 能抢占,实际:${preemptors.join(", ")}`).toEqual(["rollback"]);
  });

  it("⛔ 没有 workflow 级 concurrency —— 它会把 rollback 拉进同组**排队**,永久拆掉抢占", () => {
    expect((WF as unknown as Record<string, unknown>).concurrency).toBeUndefined();
  });

  it("production-deploy 组恰好 2 个成员:deploy-production + rollback", () => {
    const members = Object.entries(WF.jobs)
      .filter(([, j]) => j.concurrency?.group === "production-deploy")
      .map(([n]) => n)
      .sort();
    expect(members).toEqual(["deploy-production", "rollback"]);
  });

  it("rollback 用独立 environment(production-rollback)", () => {
    // ⚠️ 这个 environment 上**绝不能**有 required_reviewers —— 破窗通道被审批门挡住
    //    = 破窗通道不存在。而那条约束在 git diff 里**完全不可见**(GitHub 服务端设置)⇒
    //    只能靠 verify-system.sh 的 D 段查 API。这里只能保证它不是 'production'。
    expect(job("rollback").environment).toBe("production-rollback");
    expect(job("rollback").environment).not.toBe("production");
  });
});

// ═════════════════════════════════════════════════════════════════
describe("⑥ 测试只在 test job 里跑 —— 生产 runner 上绝不许再有 npm test", () => {
  it("⛔ 除 test job 外,任何 job 都不许跑 npm test / tsc", () => {
    // v6:deploy.sh 在 id=deploy_prod 这个 step 里跑 npm test + tsc,而回滚守卫看的是
    // 这个 step 的 outcome ⇒ **prod runner 上 vitest 抖一下就能回滚一个健康的生产。**
    // 整条流水线跑 3 次 npm test、2 次 tsc,其中第 3 次能回滚生产。
    for (const [name, j] of Object.entries(WF.jobs)) {
      if (name === "test") continue;
      for (const s of j.steps ?? []) {
        const run = s.run ?? "";
        expect(run, `job ${name}: "${s.name ?? s.id}" 在跑 npm test`).not.toMatch(/npm\s+(run\s+)?test/);
        expect(run, `job ${name}: "${s.name ?? s.id}" 在跑 tsc`).not.toMatch(/\btsc\b/);
        expect(run, `job ${name}: "${s.name ?? s.id}" 在跑 typecheck`).not.toMatch(/npm\s+run\s+typecheck/);
      }
    }
  });

  it("test job 跑 npm test(它已链了 test:workflow)", () => {
    expect(stepsWithRun("test", "npm test").length).toBeGreaterThan(0);
  });
});

// ═════════════════════════════════════════════════════════════════
describe("⑦ package.json —— workflow.spec.ts 必须真的在 CI 里跑", () => {
  it('"test" 必须链上 test:workflow', () => {
    const pkg = JSON.parse(readFileSync("package.json", "utf8")) as {
      scripts: Record<string, string>;
    };
    const t = pkg.scripts.test ?? "";
    expect(t, '"test" 没有链 test:workflow ⇒ 本文件的不变量永远不在 CI 里跑').toContain("test:workflow");
    // "vitest"(watch 模式)在没有 TTY 时才自动单跑。别赌 CI 的环境探测。
    expect(t, '"test" 必须用 vitest run,不能用裸 vitest(watch 模式)').toContain("vitest run");
  });
});

// ═════════════════════════════════════════════════════════════════
describe("⑧ 运行时文件系统事实 —— scripts/ 必须位于 checkout 之后", () => {
  it("所有包含 scripts/ 的 run step 都必须在 checkout 之后执行", () => {
    for (const [name, j] of Object.entries(WF.jobs)) {
      const stepsList = j.steps ?? [];
      const iCheckout = stepsList.findIndex((s) => (s.uses ?? "").includes("actions/checkout"));

      // 如果 job 根本没 checkout，那它肯定跑不了 scripts/
      if (iCheckout === -1) continue;

      for (const s of stepsList) {
        if ((s.run ?? "").includes("scripts/")) {
          const iScript = stepsList.indexOf(s);
          expect(
            iScript,
            `job=${name} step="${s.name ?? s.id}" 试图在 checkout 之前运行 ${s.run}`
          ).toBeGreaterThan(iCheckout);
        }
      }
    }
  });
});
