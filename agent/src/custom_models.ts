/**
 * Custom endpoints: providers that pi has no built-in entry for, defined in
 * `<agentDir>/models.json`.
 *
 * pi reads that file itself and composes it over a built-in provider with the
 * same API, so an OpenAI-compatible server (Ollama, LM Studio, vLLM, a company
 * gateway, anything that speaks `/v1/chat/completions`) becomes an ordinary
 * provider: it shows up in `providers`, resolves models, and streams through
 * pi. This module owns the file (read, validate, merge, rewrite) and probing a
 * server's `/models` list; the caller reloads ModelRuntime after each change.
 *
 * Only ids with the `custom-` prefix are managed here; anything else in
 * models.json (hand-written overrides, `modelOverrides`, ...) is left alone.
 */

import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/** The API shapes pi implements; a custom endpoint has to speak one of them. */
export const CUSTOM_APIS = [
	{ id: "openai-completions", label: "OpenAI chat completions" },
	{ id: "openai-responses", label: "OpenAI responses" },
	{ id: "anthropic-messages", label: "Anthropic messages" },
	{ id: "google-generative-ai", label: "Google Gemini" },
	{ id: "mistral-conversations", label: "Mistral conversations" },
] as const;

export type CustomApi = (typeof CUSTOM_APIS)[number]["id"];

/** Our ids are prefixed so they never collide with pi's built-in providers. */
const OWN_PREFIX = "custom-";
/** pi requires a resolvable key; local servers ignore this one. */
const NO_KEY = "not-needed";

export interface CustomModel {
	id: string;
	name?: string;
}

export interface CustomProviderInput {
	/** Kept on edit; generated from the name for a new provider. */
	id?: string;
	name: string;
	baseUrl: string;
	api?: string;
	/** Empty or missing writes [NO_KEY]; the app reports `hasKey` accordingly. */
	apiKey?: string;
	contextWindow?: number;
	maxTokens?: number;
	/** The provider's models accept image input. */
	images?: boolean;
	models: { id: string; name?: string }[];
}

export interface CustomProvider {
	id: string;
	name: string;
	baseUrl: string;
	api: string;
	hasKey: boolean;
	images: boolean;
	models: CustomModel[];
}

type ModelJson = { id: string; name?: string; contextWindow?: number; maxTokens?: number; input?: string[] };
type ProviderJson = { name?: string; baseUrl?: string; api?: string; apiKey?: string; models?: ModelJson[] };
type ModelsJson = { providers?: Record<string, ProviderJson>; [key: string]: unknown };

export class CustomModels {
	constructor(private readonly agentDir: string) {}

	get file() {
		return join(this.agentDir, "models.json");
	}

	/** Returns our own file as-is; a syntax error here must not hide pi's message. */
	private read(): ModelsJson {
		if (!existsSync(this.file)) return {};
		let parsed: unknown;
		try {
			parsed = JSON.parse(readFileSync(this.file, "utf8"));
		} catch (e) {
			throw new Error(`models.json is not valid JSON: ${(e as Error).message}`);
		}
		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
			throw new Error("models.json must contain a JSON object.");
		}
		return parsed as ModelsJson;
	}

	private write(config: ModelsJson) {
		writeFileSync(this.file, `${JSON.stringify(config, null, 2)}\n`, "utf8");
	}

	/** Every custom provider currently configured, sorted by name. */
	list(): CustomProvider[] {
		let config: ModelsJson;
		try {
			config = this.read();
		} catch {
			// A hand-edited models.json still belongs to pi to report; just list nothing.
			return [];
		}
		return Object.entries(config.providers ?? {})
			.filter(([id]) => id.startsWith(OWN_PREFIX))
			.map(([id, entry]) => ({
				id,
				name: entry.name ?? id,
				baseUrl: entry.baseUrl ?? "",
				api: entry.api ?? "openai-completions",
				hasKey: !!entry.apiKey && entry.apiKey !== NO_KEY,
				images: (entry.models ?? []).some((m) => (m.input ?? []).includes("image")),
				models: (entry.models ?? []).map((m) => ({ id: m.id, name: m.name ?? m.id })),
			}))
			.sort((a, b) => a.name.localeCompare(b.name));
	}

	/** Creates or replaces our provider, keeping the rest of models.json intact. */
	async save(input: CustomProviderInput): Promise<CustomProvider> {
		const name = String(input.name ?? "").trim();
		if (!name) throw new Error("Give the endpoint a name.");

		const rawUrl = String(input.baseUrl ?? "").trim();
		let url: URL;
		try {
			url = new URL(rawUrl);
		} catch {
			throw new Error(`"${rawUrl}" is not a URL. Use the endpoint root, e.g. http://192.168.1.20:11434/v1`);
		}
		if (url.protocol !== "http:" && url.protocol !== "https:") {
			throw new Error("The endpoint must be http:// or https://.");
		}
		const baseUrl = rawUrl.replace(/\/+$/, "");

		const api = String(input.api ?? "openai-completions");
		if (!CUSTOM_APIS.some((a) => a.id === api)) throw new Error(`Unknown API type "${api}".`);

		const seen = new Set<string>();
		const models: ModelJson[] = [];
		for (const raw of input.models ?? []) {
			const id = String(raw?.id ?? "").trim();
			if (!id || seen.has(id)) continue;
			seen.add(id);
			const model: ModelJson = { id, name: String(raw?.name ?? "").trim() || undefined };
			const contextWindow = Number(input.contextWindow);
			const maxTokens = Number(input.maxTokens);
			if (Number.isFinite(contextWindow) && contextWindow > 0) model.contextWindow = Math.round(contextWindow);
			if (Number.isFinite(maxTokens) && maxTokens > 0) model.maxTokens = Math.round(maxTokens);
			if (input.images) model.input = ["text", "image"];
			models.push(model);
		}
		if (!models.length) {
			throw new Error("Add at least one model id, or fetch them from the server.");
		}

		const config = this.read();
		// An id round-tripped from the app stays stable, so edits replace instead of stack up.
		const id = input.id?.startsWith(OWN_PREFIX) ? input.id : this.uniqueId(name);
		// A literal key (pi also accepts `$NAME` and `!command`); without one the
		// provider would resolve no auth and hide its models. The app is never shown
		// a stored key, so a blank field on an edit keeps the saved one instead of
		// quietly downgrading a keyed endpoint to NOT_KEY.
		const given = String(input.apiKey ?? "").trim();
		const apiKey = given || (config.providers ?? {})[id]?.apiKey || NO_KEY;
		const entry: ProviderJson = { name, baseUrl, api, apiKey, models };
		config.providers = { ...(config.providers ?? {}), [id]: entry };
		this.write(config);
		return {
			id,
			name,
			baseUrl,
			api,
			hasKey: apiKey !== NO_KEY,
			images: models.some((m) => (m.input ?? []).includes("image")),
			models: models.map((m) => ({ id: m.id, name: m.name ?? m.id })),
		};
	}

	/** Drops one of our providers; other entries in the file are untouched. */
	remove(providerId: string): boolean {
		if (!providerId.startsWith(OWN_PREFIX)) return false;
		const config = this.read();
		const providers = config.providers;
		if (!providers || !(providerId in providers)) return false;
		delete providers[providerId];
		if (!Object.keys(providers).length) delete config.providers;
		if (!Object.keys(config).length) rmSync(this.file, { force: true });
		else this.write(config);
		return true;
	}

	/** `custom-<slug>`, made unique against everything already in the file. */
	private uniqueId(name: string) {
		const slug =
			name
				.toLowerCase()
				.replace(/[^a-z0-9]+/g, "-")
				.replace(/^-+|-+$/g, "")
				.slice(0, 32) || "endpoint";
		const taken = new Set(Object.keys(this.read().providers ?? {}));
		let id = `${OWN_PREFIX}${slug}`;
		for (let n = 2; taken.has(id); n++) id = `${OWN_PREFIX}${slug}-${n}`;
		return id;
	}

	/** Asks the server what it has: `<baseUrl>/models`, OpenAI or Anthropic shaped. */
	async discover(baseUrl: string, apiKey?: string): Promise<CustomModel[]> {
		const root = String(baseUrl ?? "").trim().replace(/\/+$/, "");
		if (!root) throw new Error("Enter the base URL first.");
		const key = String(apiKey ?? "").trim() || NO_KEY;
		let response: Response;
		try {
			response = await fetch(`${root}/models`, {
				headers: {
					accept: "application/json",
					authorization: `Bearer ${key}`,
					// Anthropic-shaped gateways read this one instead.
					"x-api-key": key,
				},
				signal: AbortSignal.timeout(20_000),
			});
		} catch (e) {
			throw new Error(`Could not reach ${root}/models: ${(e as Error).message}`);
		}
		if (!response.ok) throw new Error(`${root}/models answered ${response.status} ${response.statusText}.`);
		let body: any;
		try {
			body = await response.json();
		} catch {
			throw new Error(`${root}/models did not answer with JSON.`);
		}
		const list: any[] = Array.isArray(body?.data)
			? body.data
			: Array.isArray(body?.models)
				? body.models
				: Array.isArray(body)
					? body
					: [];
		const models = list
			.map((m) => ({ id: String(m?.id ?? m?.name ?? "").trim(), name: String(m?.name ?? "").trim() || undefined }))
			.filter((m) => m.id)
			.slice(0, 300);
		if (!models.length) throw new Error("The server answered but listed no model ids.");
		return models;
	}
}