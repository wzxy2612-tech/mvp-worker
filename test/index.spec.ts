import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("mvp-worker /health", () => {
	it("returns 200 and the configured health JSON", async () => {
		const res = await SELF.fetch("https://example.com/health");
		expect(res.status).toBe(200);

		const body = (await res.json()) as {
			status: string;
			environment: string;
			version: string;
		};
		expect(body).toMatchObject({
			status: "OK",
			environment: "development",
			version: "v1-dev",
		});
	});

	it("returns 404 for unknown routes", async () => {
		const res = await SELF.fetch("https://example.com/does-not-exist");
		expect(res.status).toBe(404);
		expect(await res.json()).toEqual({ error: "Not Found" });
	});
});
