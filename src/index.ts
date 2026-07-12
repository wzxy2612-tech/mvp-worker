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
			// 🛡️ 1. 探活路由絕對豁免 (Health Check Bypass)
			// 流水線依賴它來判斷 Worker 存活，絕對不能被業務維護模式誤傷
			// ==========================================================
			if (url.pathname === '/health') {
				if ((env.HEALTH_MODE as string) === 'broken' && env.ENVIRONMENT !== 'production') {
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

			// ==========================================
			// 🚨 2. 邊緣動態維護模式攔截 (Gatekeeper)
			// 這裡只攔截探活以外的真實業務流量
			// ==========================================
			let isMaintenance = false;
			try {
				const rawValue = await env.CONFIG_KV.get("MAINTENANCE_MODE", { cacheTtl: 30 });
				isMaintenance = rawValue === 'true';
			} catch (e) {
				console.error("─── ⚠️ Config KV Read Failed, Failing Open ───\n", e);
			}

			if (isMaintenance) {
				statusCode = 503; 
				statusText = "Service Unavailable";
				return new Response(
					JSON.stringify({ 
						success: false, 
						message: "The system is currently undergoing scheduled maintenance. Please try again later." 
					}), 
					{ 
						status: 503, 
						headers: { 
							"Content-Type": "application/json",
							"Retry-After": "60" 
						} 
					}
				);
			}

			// ==========================================================
			// 🚦 3. 其他未定義路徑 (404) - 你的真實業務邏輯
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