export interface Env {
	ENVIRONMENT: string;
	APP_VERSION: string;
	// demo/測試用：值為 "broken" 時讓 /health 回 500，用來演練健康閘門 + 自動回滾。
	// 僅在非 production 環境生效（見下方判斷），避免誤傷正式環境。
	HEALTH_MODE?: string;
}

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const startTime = Date.now();
		const url = new URL(request.url);
		let statusCode = 200;
		let statusText = "OK";

		// 統一 CORS 標頭，套用到所有回應（原本只加在 /health）。
		// 註：若需真正的瀏覽器預檢，還要處理 OPTIONS 並加 Allow-Methods/Headers。
		const baseHeaders: Record<string, string> = {
			'Content-Type': 'application/json',
			'Access-Control-Allow-Origin': '*',
		};

		try {
			// 1. /health 端點
			if (url.pathname === '/health') {
				// demo 失敗注入：非 production 且 HEALTH_MODE=broken → 回 500
				if (env.HEALTH_MODE === 'broken' && env.ENVIRONMENT !== 'production') {
					statusCode = 500;
					statusText = "Simulated Failure";
					return new Response(
						JSON.stringify({ status: 'ERROR', reason: 'simulated failure', version: env.APP_VERSION }),
						{ status: 500, headers: baseHeaders },
					);
				}

				const healthData = {
					status: 'OK',
					timestamp: new Date().toISOString(),
					environment: env.ENVIRONMENT,
					version: env.APP_VERSION,
				};
				return new Response(JSON.stringify(healthData), {
					status: 200,
					headers: baseHeaders,
				});
			}

			// 2. 其他未定義路徑返回 404
			statusCode = 404;
			statusText = "Not Found";
			return new Response(JSON.stringify({ error: 'Not Found' }), {
				status: 404,
				headers: baseHeaders,
			});

		} catch (error: unknown) {
			statusCode = 500;
			statusText = "Internal Server Error";

			// 收斂為標準 Error 後再取 message/stack（比 error: any 型別安全）
			const err = error instanceof Error ? error : new Error(String(error));

			// 結構化異常紀錄：拋出標準 JSON 到 Cloudflare Log Stream
			console.log(JSON.stringify({
				level: "ERROR",
				message: err.message,
				stack: err.stack,
				timestamp: new Date().toISOString(),
			}));

			return new Response(JSON.stringify({ error: 'Internal Server Error' }), {
				status: 500,
				headers: baseHeaders,
			});
		} finally {
			// 3. 邊緣原生指標計算：無論如何都會執行
			//
			// ⚠ Workers 為防 Spectre，Date.now() 鎖在「上一次 I/O 的時間」，同步執行期間不前進。
			//   本 handler 無任何 I/O（fetch/KV/D1…），故 duration_ms 在「線上」恆為 ~0；
			//   本地 wrangler dev（workerd）時鐘照常走，會有非 0 值，屬正常差異。
			//   → 權威延遲數據請以 Cloudflare Analytics 為準（get_metrics.sh 的 durationP90）。
			//   → 此欄位僅對未來含 I/O 的路由具測量意義；若不想在正式日誌看到誤導值，可移除。
			const durationMs = Date.now() - startTime;

			// 強制格式化為結構化指標，供後端 Logpush 或 Dashboard 解析
			console.log(JSON.stringify({
				level: "INFO",
				type: "request_metric",
				method: request.method,
				path: url.pathname,
				status: statusCode,
				statusText: statusText,
				duration_ms: durationMs,
				timestamp: new Date().toISOString(),
			}));
		}
	},
};
