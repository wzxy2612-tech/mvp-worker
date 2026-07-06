# MVP Worker — 發佈 / 回滾 / 監控

最小可運行的 Cloudflare Worker（TypeScript），加一套生產級發佈腳本：備份、含健康閘門的部署、失敗自動回滾、指標查詢，以及把它們串起來的編排器。

## 目錄結構

```
.
├── scripts/
│   ├── .gitattributes     # 強制 *.sh / .env 為 LF 行尾
│   ├── utils.sh           # 共用：log / JSON 輸出 / 憑證載入 / 可攜 date
│   ├── backup.sh          # 備份本地設定 + Cloudflare Zone 路由
│   ├── deploy.sh          # 部署 + 冒煙測試健康閘門
│   ├── deploy_check.sh    # 部署前的本地 dev 健康檢查（選用）
│   ├── rollback.sh        # wrangler 原生回滾 + 設定檔還原
│   ├── get_metrics.sh     # 查 GraphQL Analytics（requests / error rate / p90）
│   ├── promote.sh         # 線上版本晉升（從 staging → production）
│   └── release.sh         # 編排：backup → deploy → 失敗自動 rollback
├── src/
│   └── index.ts           # Worker：GET / 與 GET /health，結構化日誌 + request_metric
├── test/
│   ├── tsconfig.json      # 測試專用 tsconfig（繼承父層，追加 cloudflare:test 型別）
│   └── index.spec.ts      # Vitest 測試：/health 200 + 未知路徑 404
├── wrangler.jsonc         # Worker 設定（vars 含 ENVIRONMENT / APP_VERSION / HEALTH_MODE）
├── tsconfig.json          # 型別檢查用（wrangler 以 esbuild 打包，執行不需要）
├── vitest.config.mts      # Vitest 設定（使用 @cloudflare/vitest-pool-workers 的 cloudflareTest）
├── worker-configuration.d.ts  # wrangler types 自動產生的 binding 型別
├── .env                   # 環境變數（Cloudflare 憑證等，已 gitignore）
├── .editorconfig
├── .prettierrc
├── AGENTS.md              # 給 AI 助手的專案指引
└── backups/               # backup.sh 產出的備份目錄
```

## 前置需求

- Node.js + npx（wrangler 透過 npx 呼叫，免全域安裝）
- jq（腳本以 jq 解析 JSON）
- 一個 Cloudflare 帳號；擇一認證：
  - `npx wrangler login`（OAuth，本機開發最簡單），或
  - 環境變數 `CLOUDFLARE_ACCOUNT_ID` + `CLOUDFLARE_API_TOKEN`（CI 建議）
- 註：`backup.sh` 的路由匯出與 `get_metrics.sh` 需要 **API token**（上面第二種）。可放進 `.env`（請保持 LF 行尾）。

## 快速開始

```bash
npm install                   # 安裝依賴（wrangler / typescript / vitest / @cloudflare/workers-types …）
npm test                      # 跑 Vitest（workerd 隔離環境，驗證 /health 與 404 路由）
npx wrangler dev              # 本機起 dev → http://localhost:8787/health
bash scripts/release.sh       # 一鍵：備份 → 部署 → 健康閘門 → 失敗自動回滾
bash scripts/get_metrics.sh   # 查線上指標
```

> 請在專案根目錄執行（`wrangler.jsonc` 與 `./backups` 皆相對於 CWD）。

## 測試

使用 `vitest` + `@cloudflare/vitest-pool-workers`，在 workerd 隔離環境中執行：

```bash
npm test                      # vitest（自動載入 vitest.config.mts）
```

測試斷言值直接來自 `wrangler.jsonc` 的 vars（`ENVIRONMENT=development`, `APP_VERSION=v1`），確保測試與部署配置同源。

## 演練「壞版自動回滾」

失敗注入只在**非 production** 環境生效（`wrangler.jsonc` 預設 `ENVIRONMENT: "development"`，可直接演練）。

1. 先正常發一版：`bash scripts/release.sh` → 應通過健康閘門、成功（此為「好版 v1」）。
2. 把 `wrangler.jsonc` 的 `HEALTH_MODE` 改成 `"broken"`（此時 `/health` 回 500）。
3. 再跑 `bash scripts/release.sh`：wrangler 上傳「壞版 v2」→ 冒煙測試連續失敗 → **自動觸發 rollback** → 回到 v1（其 vars 為 `HEALTH_MODE: ok`），線上服務恢復。
4. 把 `HEALTH_MODE` 改回 `"ok"`，確認狀態一致。

## 輸出契約

所有腳本：人類可讀 log 走 **stderr**；結尾一行結構化 JSON 走 **stdout**：

```json
{ "success": true, "message": "...", "data": { ... }, "timestamp": 1730000000 }
```

`deploy.sh` / `rollback.sh` 會在 `data.required_action` 給出下一步：`none`（無需動作）、`rollback`（該回滾）、`manual_review_code`（已回滾，請人工查程式碼）、`manual_intervention`（回滾也失敗，需人工介入）。`release.sh` 就是靠讀這個欄位決定是否自動回滾。

Worker 端則以 `console.log(JSON.stringify(...))` 輸出結構化日誌到 Cloudflare Log Stream（`level: ERROR` 例外、`type: request_metric` 每請求指標），供 wrangler tail / Logpush / Dashboard 解析。

## 可調環境變數（皆有預設值）

| 變數 | 用途 | 預設 |
| --- | --- | --- |
| `HEALTH_URL` | 直接指定線上健康檢查 URL（自訂網域/route 用） | 從 deploy 輸出解析 |
| `HEALTH_PATH` | 健康檢查路徑 | `/health` |
| `SMOKE_CHECKS` | 需連續成功的輪數 | `3` |
| `SMOKE_RETRIES` | 單輪容錯重試次數 | `3` |
| `SMOKE_ROUND_GAP` | 輪與輪之間隔（秒） | `5` |
| `METRICS_WINDOW_MINUTES` | 指標查詢時間窗 | `5` |
| `LOCAL_HEALTH_URL` | 本地檢查端點 | `http://localhost:8787/health` |
| `SCRIPT_NAME` | Worker 名稱（查指標用） | `mvp-worker` |

Worker 的 `wrangler.jsonc` vars：`ENVIRONMENT`（設 `production` 會關閉失敗注入）、`APP_VERSION`、`HEALTH_MODE`（`broken` 觸發 /health 500，僅非 production 生效）。

## 注意事項

- **延遲量測**：Workers 為防 Spectre，`Date.now()` 鎖在上一次 I/O 的時間，同步路徑（如 /health）算出的 `duration_ms` 在線上恆為 ~0（本地 dev 會有非 0 值）。權威延遲以 `get_metrics.sh` 的 `durationP90` 為準；worker 內的 `duration_ms` 僅對含 I/O 的路由有意義。
- `wrangler rollback` 的確認流程隨版本略有差異，`rollback.sh` 以 `printf 'y'` 餵入為最可攜做法；若回滾目標版本的 **secret 值與當前不同**，Cloudflare 會額外要求確認。請在你的 wrangler 版本上實測一次。
- `get_metrics.sh` 查的 GraphQL analytics 有數分鐘傳播延遲，適合「事後/持續」觀測；部署當下的即時信號以 `deploy.sh` 的直連 curl 為準。
- 回滾只還原「程式碼 + 本地設定檔」；KV / D1 / R2 / Durable Objects 的**狀態資料**與 secrets 不在此範圍（若客戶需要，需另外設計、單獨排期）。
