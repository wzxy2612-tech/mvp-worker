export interface Env {
	// 只有基础設定與健康閘門變數，沒有任何 Secret
	ENVIRONMENT: string;
	APP_VERSION: string;
	HEALTH_MODE?: string;
}
const toxic_code = ; // 故意留空引發編譯失敗
const BASE_HEADERS: Record<string, string> = {
	'Content-Type': 'application/json',
};

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const startTime = Date.now();
		const url = new URL(request.url);
		let statusCode = 200;
		let statusText = "OK";

		try {
			// ==========================================================
			// 1. /health 端點 (純淨的探活邏輯)
			// ==========================================================
			if (url.pathname === '/health') {
				if (env.HEALTH_MODE === 'broken' && env.ENVIRONMENT !== 'production') {
					statusCode = 500;
					statusText = "Simulated Failure";
					return new Response(
						JSON.stringify({ status: 'ERROR', reason: 'simulated failure', version: env.APP_VERSION }),
						{ status: 500, headers: BASE_HEADERS },
					);
				}

				statusCode = 200;
				statusText = "OK";
				return json({
					status: 'OK',
					timestamp: new Date().toISOString(),
					environment: env.ENVIRONMENT,
					version: env.APP_VERSION,
				}, statusCode, statusText);
			}

			// ==========================================================
			// 其他未定義路徑 (404) - 未來這裡放你的真實業務邏輯
			// ==========================================================
			statusCode = 404;
			statusText = "Not Found";
			return json({ error: 'Not Found' }, 404, statusText);

		} catch (error: unknown) {
			statusCode = 500;
			statusText = "Internal Server Error";
			const err = error instanceof Error ? error : new Error(String(error));
			console.log(JSON.stringify({ level: "ERROR", message: err.message, stack: err.stack, timestamp: new Date().toISOString() }));
			return json({ error: 'Internal Server Error' }, 500, statusText);
		} finally {
			const durationMs = Date.now() - startTime;
			console.log(JSON.stringify({
				level: "INFO", type: "request_metric", method: request.method,
				path: url.pathname, status: statusCode, statusText: statusText,
				duration_ms: durationMs, timestamp: new Date().toISOString(),
			}));
		}
	},
};

function json(payload: unknown, status = 200, statusText = "OK"): Response {
	return new Response(JSON.stringify(payload), { status, statusText, headers: BASE_HEADERS });
}