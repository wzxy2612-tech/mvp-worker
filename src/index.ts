export interface Env {
	ENVIRONMENT: string;
	APP_VERSION: string;
}

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const startTime = Date.now();
		const url = new URL(request.url);
		let statusCode = 200;
		let statusText = "OK";

		try {
			// 1. 處理 /health 端點
			if (url.pathname === '/health' || url.pathname === 'health') {
				const healthData = {
					status: 'OK',
					timestamp: new Date().toISOString(),
					environment: env.ENVIRONMENT,
					version: env.APP_VERSION,
				};
				return new Response(JSON.stringify(healthData), {
					status: 200,
					headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
				});
			}

			// 2. 其他未定義路徑返回 404
			statusCode = 404;
			statusText = "Not Found";
			return new Response(JSON.stringify({ error: 'Not Found' }), {
				status: 404,
				headers: { 'Content-Type': 'application/json' },
			});

		} catch (error: any) {
			statusCode = 500;
			statusText = "Internal Server Error";

			// 結構化異常紀錄：拋出標準 JSON 到 Cloudflare Log Stream
			console.log(JSON.stringify({
				level: "ERROR",
				message: error.message || "Unknown error",
				stack: error.stack,
				timestamp: new Date().toISOString()
			}));

			return new Response(JSON.stringify({ error: 'Internal Server Error' }), {
				status: 500,
				headers: { 'Content-Type': 'application/json' },
			});
		} finally {
			// 3. 邊緣原生指標計算：無論如何都會執行
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
				timestamp: new Date().toISOString()
			}));
		}
	},
};