/**
 * MCP (Model Context Protocol) servers as pi tools. Each connected server's
 * tools become `mcp_<server>_<tool>`. Servers run as local commands (stdio,
 * optionally inside the Linux container so `npx`/`uvx` work) or over HTTP.
 */

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { randomUUID } from "node:crypto";
import { Type } from "typebox";
import { readSecureJson, writeSecureJson } from "./secure.js";

export interface McpServerConfig {
	id: string;
	name: string;
	type: "stdio" | "http";
	/** stdio: the command line, e.g. `npx -y @modelcontextprotocol/server-filesystem ~/workspace`. */
	command?: string;
	/** stdio: run through the Linux container (`box -c ...`). */
	inContainer?: boolean;
	env?: Record<string, string>;
	/** http: the endpoint, plus optional headers (e.g. Authorization). */
	url?: string;
	headers?: Record<string, string>;
	enabled: boolean;
}

interface Live {
	client: Client;
	tools: { name: string; description?: string; inputSchema: any }[];
	status: "connected" | "error" | "connecting";
	error?: string;
}

const toolName = (server: string, tool: string) =>
	`mcp_${server}_${tool}`.replace(/[^A-Za-z0-9_-]+/g, "_").slice(0, 64);

export class Mcp {
	private servers: McpServerConfig[] = [];
	private live = new Map<string, Live>();

	constructor(
		private readonly file: string,
		private readonly onChange: () => void,
	) {
		this.servers = readSecureJson<McpServerConfig[]>(file, []);
	}

	private save() {
		writeSecureJson(this.file, this.servers);
	}

	summary() {
		return this.servers.map((s) => {
			const l = this.live.get(s.id);
			return {
				...s,
				// Secrets stay on the device side; the app only sees which keys exist.
				env: Object.fromEntries(Object.keys(s.env ?? {}).map((k) => [k, "•••"])),
				headers: Object.fromEntries(Object.keys(s.headers ?? {}).map((k) => [k, "•••"])),
				status: s.enabled ? (l?.status ?? "connecting") : "disabled",
				error: l?.error ?? null,
				tools: (l?.tools ?? []).map((t) => ({ name: t.name, description: t.description ?? "" })),
			};
		});
	}

	async connectAll() {
		await Promise.all(this.servers.filter((s) => s.enabled).map((s) => this.connect(s)));
	}

	private async connect(s: McpServerConfig) {
		await this.disconnect(s.id);
		const entry: Live = { client: new Client({ name: "andropi", version: "1.0.0" }), tools: [], status: "connecting" };
		this.live.set(s.id, entry);
		this.onChange();
		try {
			const transport =
				s.type === "http"
					? new StreamableHTTPClientTransport(new URL(s.url!), { requestInit: { headers: s.headers ?? {} } })
					: new StdioClientTransport(
							s.inContainer
								? { command: "box", args: ["-c", s.command!], env: { ...(process.env as any), ...s.env }, stderr: "pipe" }
								: {
										command: "/system/bin/sh",
										args: ["-c", s.command!],
										env: { ...(process.env as any), ...s.env },
										stderr: "pipe",
									},
						);
			await entry.client.connect(transport);
			const { tools } = await entry.client.listTools();
			entry.tools = tools as any;
			entry.status = "connected";
		} catch (e) {
			entry.status = "error";
			entry.error = String((e as Error).message ?? e).slice(0, 300);
		}
		this.onChange();
	}

	private async disconnect(id: string) {
		const l = this.live.get(id);
		this.live.delete(id);
		await l?.client.close().catch(() => {});
	}

	async upsert(cfg: Partial<McpServerConfig>) {
		if (!cfg.name?.trim()) throw new Error("Give the server a name");
		const prev = cfg.id ? this.servers.find((s) => s.id === cfg.id) : undefined;
		// Masked values from the app mean "keep the stored secret".
		const merge = (next: Record<string, string> | undefined, old: Record<string, string> | undefined) =>
			next ? Object.fromEntries(Object.entries(next).map(([k, v]) => [k, v === "•••" ? (old?.[k] ?? "") : v])) : old;
		const s: McpServerConfig = {
			id: cfg.id ?? randomUUID(),
			name: cfg.name.trim().replace(/[^A-Za-z0-9_-]+/g, "_"),
			type: cfg.type === "http" ? "http" : "stdio",
			command: cfg.command?.trim(),
			inContainer: !!cfg.inContainer,
			env: merge(cfg.env, prev?.env),
			url: cfg.url?.trim(),
			headers: merge(cfg.headers, prev?.headers),
			enabled: cfg.enabled ?? true,
		};
		if (s.type === "stdio" && !s.command) throw new Error("Enter the command that starts the server");
		if (s.type === "http" && !s.url) throw new Error("Enter the server URL");
		const i = this.servers.findIndex((x) => x.id === s.id);
		if (i >= 0) this.servers[i] = s;
		else this.servers.push(s);
		this.save();
		if (s.enabled) await this.connect(s);
		else await this.disconnect(s.id);
		return this.summary();
	}

	async remove(id: string) {
		this.servers = this.servers.filter((s) => s.id !== id);
		this.save();
		await this.disconnect(id);
		this.onChange();
		return this.summary();
	}

	/** pi tool definitions for every connected server. */
	toolDefinitions() {
		const defs: any[] = [];
		for (const s of this.servers) {
			const l = this.live.get(s.id);
			if (!s.enabled || l?.status !== "connected") continue;
			for (const t of l.tools) {
				defs.push({
					name: toolName(s.name, t.name),
					label: `${s.name}: ${t.name}`,
					description: `[MCP ${s.name}] ${t.description ?? t.name}`.slice(0, 1024),
					parameters: Type.Unsafe(t.inputSchema ?? { type: "object", properties: {} }),
					async execute(_id: string, params: any) {
						const result: any = await l.client.callTool({ name: t.name, arguments: params ?? {} });
						const content = (result.content ?? []).map((c: any) =>
							c.type === "image"
								? { type: "image", data: c.data, mimeType: c.mimeType }
								: { type: "text", text: c.type === "text" ? c.text : JSON.stringify(c) },
						);
						if (result.isError) throw new Error(content.map((c: any) => c.text ?? "").join("\n") || "MCP tool failed");
						return { content: content.length ? content : [{ type: "text", text: "(no output)" }], details: undefined };
					},
				});
			}
		}
		return defs;
	}

	async dispose() {
		await Promise.all([...this.live.keys()].map((id) => this.disconnect(id)));
	}
}
