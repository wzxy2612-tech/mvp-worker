export interface Env {
	// ==========================================================
	// 基礎設定與健康閘門變數
	// ==========================================================
	ENVIRONMENT: string;
	APP_VERSION: string;
	HEALTH_MODE?: string;

	// ==========================================================
	// GitHub CI/CD 控制面變數 (供 /trigger 與 /status 使用)
	// ==========================================================
	GITHUB_TOKEN: string;          // PAT (Repo + Workflow scope) 
	TRIGGER_SECRET: string;        // 呼叫端必須提供的共享密鑰
	GITHUB_OWNER: string;          // GitHub 組織或使用者名稱
	GITHUB_REPO: string;           // GitHub 倉庫名稱
	GITHUB_WORKFLOW_FILE: string;  // Workflow 檔案名稱 (例如: deploy.yml)
}

// 統一 CORS 標頭，提取到全域以供所有路徑與 Helper 函數使用
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
			// 1. /health 端點 (現有探活邏輯)
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

                             // [新增] 顯式賦值，防禦未來頂部預設值被修改導致的日誌脫節
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
			// 2. /trigger 端點 (新增 CI 觸發)
			// ==========================================================
			if (url.pathname === '/trigger' && request.method === 'POST') {
				const res = await handleTrigger(request, env);
				statusCode = res.status;
				statusText = res.statusText || "Trigger Processed";
				return res;
			}

			// ==========================================================
			// 3. /status 端點 (新增 CI 狀態查詢)
			// ==========================================================
			if (url.pathname === '/status' && request.method === 'GET') {
				const res = await handleStatus(request, env);
				statusCode = res.status;
				statusText = res.statusText || "Status Fetched";
				return res;
			}

			// ==========================================================
			// 4. 其他未定義路徑 (404)
			// ==========================================================
			statusCode = 404;
			statusText = "Not Found";
			return json({ error: 'Not Found' }, 404, statusText);

		} catch (error: unknown) {
			statusCode = 500;
			statusText = "Internal Server Error";
			const err = error instanceof Error ? error : new Error(String(error));

			// 結構化異常紀錄
			console.log(JSON.stringify({
				level: "ERROR",
				message: err.message,
				stack: err.stack,
				timestamp: new Date().toISOString(),
			}));

			return json({ error: 'Internal Server Error' }, 500, statusText);
		} finally {
			// ==========================================================
			// 邊緣原生指標計算與結構化日誌輸出 (所有請求皆會經過)
			// ==========================================================
			const durationMs = Date.now() - startTime;
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

// ============================================================================
// 下方為 GitHub API 控制面輔助函數區 (Helper Functions)
// ============================================================================

const VALID_ACTIONS = ["deploy", "rollback"] as const;
type Action = (typeof VALID_ACTIONS)[number];

async function handleTrigger(request: Request, env: Env): Promise<Response> {
	const authFailure = checkSecret(request, env);
	if (authFailure) return authFailure;

	let body: { action?: string; ref?: string };
	try {
		body = await request.json();
	} catch {
		return json({ success: false, message: "invalid JSON body" }, 400, "Bad Request");
	}

	if (!isValidAction(body.action)) {
		return json(
			{ success: false, message: `action must be one of: ${VALID_ACTIONS.join(", ")}` },
			400, 
			"Bad Request"
		);
	}

	const ref = body.ref ?? "main";

	const res = await ghFetch(
		env,
		`/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/actions/workflows/${env.GITHUB_WORKFLOW_FILE}/dispatches`,
		{
			method: "POST",
			body: JSON.stringify({ ref, inputs: { action: body.action } }),
		}
	);

	if (res.status === 204) {
		return json({ success: true, message: `dispatched ${body.action}`, data: { ref } }, 200, "OK");
	}

	return json(
		{
			success: false,
			message: "GitHub dispatch failed",
			data: { status: res.status, body: await res.text() },
		},
		502,
		"Bad Gateway"
	);
}

async function handleStatus(request: Request, env: Env): Promise<Response> {
	const authFailure = checkSecret(request, env);
	if (authFailure) return authFailure;

	const res = await ghFetch(
		env,
		`/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/actions/workflows/${env.GITHUB_WORKFLOW_FILE}/runs?per_page=1`
	);
	
	if (!res.ok) {
		return json({ success: false, message: "failed to fetch runs" }, 502, "Bad Gateway");
	}

	const data = (await res.json()) as { workflow_runs: GhRun[] };
	const run = data.workflow_runs[0];
	
	if (!run) {
		return json({ success: true, message: "no runs yet", data: null }, 200, "OK");
	}

	return json({
		success: true,
		data: {
			run_number: run.run_number,
			display_title: run.display_title,
			status: run.status,
			conclusion: run.conclusion,
			html_url: run.html_url,
			created_at: run.created_at,
			updated_at: run.updated_at,
		},
	}, 200, "OK");
}

interface GhRun {
	run_number: number;
	display_title: string;
	status: string;
	conclusion: string | null;
	html_url: string;
	created_at: string;
	updated_at: string;
}

function isValidAction(action?: string): action is Action {
	return !!action && (VALID_ACTIONS as readonly string[]).includes(action);
}

function checkSecret(request: Request, env: Env): Response | null {
	const provided = request.headers.get("X-Trigger-Secret") ?? "";
	if (!timingSafeEqual(provided, env.TRIGGER_SECRET)) {
		return json({ success: false, message: "unauthorized" }, 401, "Unauthorized");
	}
	return null;
}

function timingSafeEqual(a: string, b: string): boolean {
	const enc = new TextEncoder();
	const aBytes = enc.encode(a);
	const bBytes = enc.encode(b);
	if (aBytes.length !== bBytes.length) return false;
	let diff = 0;
	for (let i = 0; i < aBytes.length; i++) diff |= aBytes[i] ^ bBytes[i];
	return diff === 0;
}

async function ghFetch(env: Env, path: string, init: RequestInit = {}): Promise<Response> {
	return fetch(`https://api.github.com${path}`, {
		...init,
		headers: {
			Authorization: `Bearer ${env.GITHUB_TOKEN}`,
			Accept: "application/vnd.github+json",
			"X-GitHub-Api-Version": "2022-11-28",
			"Content-Type": "application/json",
			"User-Agent": "mvp-worker-trigger",
			...(init.headers ?? {}),
		},
	});
}

// 覆寫的 json helper：自動注入全域 BASE_HEADERS 並允許自訂 HTTP Status Code / Text
function json(payload: unknown, status = 200, statusText = "OK"): Response {
	return new Response(JSON.stringify(payload), {
		status,
		statusText,
		headers: BASE_HEADERS,
	});
}