import {
	env,
	createExecutionContext,
	waitOnExecutionContext,
	SELF,
} from "cloudflare:test";
import { describe, it, expect } from "vitest";
import worker from "../src/index";

const IncomingRequest = Request<unknown, IncomingRequestCfProperties>;

describe("MVP Worker", () => {
	it("responds with 200 and health JSON at /health (unit style)", async () => {
		const request = new IncomingRequest("http://example.com/health");
		const ctx = createExecutionContext();
		const response = await worker.fetch(request, env, ctx);
		await waitOnExecutionContext(ctx);
		expect(response.status).toBe(200);
		const body = await response.json<Record<string, unknown>>();
		expect(body).toMatchObject({
			status: "OK",
			environment: "staging",
			version: "1.0.0",
		});
		expect(body).toHaveProperty("timestamp");
	});

	it("responds with 404 for unknown routes (unit style)", async () => {
		const request = new IncomingRequest("http://example.com/");
		const ctx = createExecutionContext();
		const response = await worker.fetch(request, env, ctx);
		await waitOnExecutionContext(ctx);
		expect(response.status).toBe(404);
		const body = await response.json<Record<string, unknown>>();
		expect(body).toEqual({ error: "Not Found" });
	});

	it("responds with 200 and health JSON at /health (integration style)", async () => {
		const response = await SELF.fetch("https://example.com/health");
		expect(response.status).toBe(200);
		const body = await response.json<Record<string, unknown>>();
		expect(body).toMatchObject({
			status: "OK",
			environment: "staging",
			version: "1.0.0",
		});
	});

	it("responds with 404 for unknown routes (integration style)", async () => {
		const response = await SELF.fetch("https://example.com/");
		expect(response.status).toBe(404);
		const body = await response.json<Record<string, unknown>>();
		expect(body).toEqual({ error: "Not Found" });
	});
});
