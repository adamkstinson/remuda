/**
 * Load the host `browser` MCP from mcp.json and register browser_screenshot.
 * Sandbox reaches the host via host.docker.internal (see Remuda ExtraHosts).
 */

import { Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync } from "node:fs";
import { hostname } from "node:os";
import { dirname, resolve } from "node:path";

function mcpJsonPaths(): string[] {
	const found: string[] = [];
	for (const start of [process.cwd(), "/agent"]) {
		let dir = start;
		for (let i = 0; i < 8; i++) {
			const path = resolve(dir, "mcp.json");
			if (existsSync(path) && !found.includes(path)) found.push(path);
			const parent = dirname(dir);
			if (parent === dir) break;
			dir = parent;
		}
	}
	return found;
}

function browserMcpUrl(): string | undefined {
	if (process.env.REMUDA_BROWSER_MCP_URL) return process.env.REMUDA_BROWSER_MCP_URL;

	for (const path of mcpJsonPaths()) {
		try {
			const config = JSON.parse(readFileSync(path, "utf8")) as {
				mcpServers?: Record<string, { url?: string; tailscale_url?: string }>;
			};
			const spec = config.mcpServers?.browser;
			if (!spec) continue;
			const onServer = hostname().split(".")[0] === "adam-server";
			const url = onServer ? spec.url || spec.tailscale_url : spec.tailscale_url || spec.url;
			if (url) return url;
		} catch {
			// missing or unreadable
		}
	}
	return undefined;
}

function mapContent(raw: unknown): Array<Record<string, unknown>> {
	if (!raw || typeof raw !== "object") {
		return [{ type: "text", text: JSON.stringify(raw) }];
	}
	const result = raw as { content?: unknown };
	if (!Array.isArray(result.content)) {
		return [{ type: "text", text: JSON.stringify(raw) }];
	}

	const content: Array<Record<string, unknown>> = [];
	for (const part of result.content) {
		if (!part || typeof part !== "object") continue;
		const item = part as {
			type?: string;
			text?: string;
			data?: string;
			mimeType?: string;
		};
		if (item.type === "image" && item.data) {
			content.push({
				type: "image",
				source: {
					type: "base64",
					mediaType: item.mimeType || "image/png",
					data: item.data,
				},
			});
			continue;
		}
		if (item.type === "text" && item.text) {
			content.push({ type: "text", text: item.text });
		}
	}
	return content.length > 0 ? content : [{ type: "text", text: JSON.stringify(raw) }];
}

async function rpc(url: string, method: string, params: Record<string, unknown>, signal?: AbortSignal) {
	const response = await fetch(url, {
		method: "POST",
		headers: { "content-type": "application/json" },
		body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
		signal,
	});
	if (!response.ok) {
		throw new Error(`browser MCP HTTP ${response.status}`);
	}
	const payload = (await response.json()) as { error?: { message?: string }; result?: unknown };
	if (payload.error) {
		throw new Error(payload.error.message || JSON.stringify(payload.error));
	}
	return payload.result;
}

export default function (pi: ExtensionAPI) {
	const url = browserMcpUrl();
	if (!url) return;

	pi.registerTool({
		name: "browser_screenshot",
		label: "Screenshot",
		description:
			"Open a local URL in the host browser service and return a PNG. Use after changing a screen or mockup. Only localhost and host.docker.internal URLs are allowed.",
		parameters: Type.Object({
			url: Type.String({ description: "http URL of the running app or mockup" }),
			width: Type.Optional(Type.Number({ description: "Viewport width. Default 1440." })),
			height: Type.Optional(Type.Number({ description: "Viewport height. Default 900." })),
			full_page: Type.Optional(Type.Boolean({ description: "Capture the full page instead of the viewport." })),
		}),
		promptSnippet: "browser_screenshot: capture a local page as a PNG",
		promptGuidelines: [
			"Use browser_screenshot after changing a screen or mockup. You are not done until you have looked at the image.",
			"Call browser_screenshot at 375, 768, and 1440 wide for UI work.",
		],
		async execute(_toolCallId, params, signal) {
			const result = await rpc(
				url,
				"tools/call",
				{
					name: "screenshot",
					arguments: {
						url: params.url,
						width: params.width,
						height: params.height,
						full_page: params.full_page,
					},
				},
				signal,
			);
			return { content: mapContent(result), details: {} };
		},
	});
}
