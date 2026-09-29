/**
 * web_search and web_fetch tools, so the agent can look up install steps,
 * docs and error messages instead of guessing.
 *
 * Search works without a key (DuckDuckGo, DuckDuckGo Lite, then Brave, scraped
 * from their HTML pages). A Brave Search or Tavily key, when configured, is used first.
 */

import { Type } from "typebox";

const UA =
	"Mozilla/5.0 (Linux; Android 15; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Mobile Safari/537.36";

export interface SearchResult {
	title: string;
	url: string;
	snippet: string;
}

export interface SearchKeys {
	brave?: string;
	tavily?: string;
}

// ---------------------------------------------------------------------------
// Search backends

async function braveSearch(q: string, n: number, key: string, signal?: AbortSignal): Promise<SearchResult[]> {
	const res = await fetch(`https://api.search.brave.com/res/v1/web/search?q=${encodeURIComponent(q)}&count=${n}`, {
		headers: { Accept: "application/json", "X-Subscription-Token": key },
		signal,
	});
	if (!res.ok) throw new Error(`Brave ${res.status}`);
	const body = (await res.json()) as any;
	return (body.web?.results ?? []).map((r: any) => ({
		title: r.title,
		url: r.url,
		snippet: stripTags(r.description ?? ""),
	}));
}

async function tavilySearch(q: string, n: number, key: string, signal?: AbortSignal): Promise<SearchResult[]> {
	const res = await fetch("https://api.tavily.com/search", {
		method: "POST",
		headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
		body: JSON.stringify({ query: q, max_results: n }),
		signal,
	});
	if (!res.ok) throw new Error(`Tavily ${res.status}`);
	const body = (await res.json()) as any;
	return (body.results ?? []).map((r: any) => ({ title: r.title, url: r.url, snippet: r.content ?? "" }));
}

async function duckSearch(q: string, n: number, signal?: AbortSignal): Promise<SearchResult[]> {
	const res = await fetch("https://html.duckduckgo.com/html/", {
		method: "POST",
		headers: { "User-Agent": UA, "Content-Type": "application/x-www-form-urlencoded" },
		body: `q=${encodeURIComponent(q)}&kl=wt-wt`,
		signal,
	});
	if (!res.ok) throw new Error(`DuckDuckGo ${res.status}`);
	const html = await res.text();
	const out: SearchResult[] = [];
	const block = /<div class="result results_links[\s\S]*?(?=<div class="result results_links|<\/div>\s*<\/div>\s*<div id="links_wrapper"|$)/g;
	for (const m of html.matchAll(block)) {
		const a = m[0].match(/class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/);
		if (!a) continue;
		let url = decodeEntities(a[1]);
		const uddg = url.match(/[?&]uddg=([^&]+)/);
		if (uddg) url = decodeURIComponent(uddg[1]);
		if (url.startsWith("//")) url = `https:${url}`;
		if (/duckduckgo\.com\/y\.js/.test(url)) continue; // ads
		const s = m[0].match(/class="result__snippet"[^>]*>([\s\S]*?)<\/a>/);
		out.push({ title: stripTags(a[2]), url, snippet: stripTags(s?.[1] ?? "") });
		if (out.length >= n) break;
	}
	if (out.length === 0) throw new Error("DuckDuckGo returned no results");
	return out;
}

const DESKTOP_UA =
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36";

async function duckLiteSearch(q: string, n: number, signal?: AbortSignal): Promise<SearchResult[]> {
	const res = await fetch("https://lite.duckduckgo.com/lite/", {
		method: "POST",
		headers: { "User-Agent": DESKTOP_UA, "Content-Type": "application/x-www-form-urlencoded" },
		body: `q=${encodeURIComponent(q)}`,
		signal,
	});
	if (!res.ok) throw new Error(`DuckDuckGo Lite ${res.status}`);
	const html = await res.text();
	const links = [...html.matchAll(/<a[^>]*href="([^"]+)"[^>]*class=['"]result-link['"][^>]*>([\s\S]*?)<\/a>/g)];
	const snippets = [...html.matchAll(/class=['"]result-snippet['"][^>]*>([\s\S]*?)<\/td>/g)];
	const out: SearchResult[] = [];
	links.forEach((m, i) => {
		let url = decodeEntities(m[1]);
		const uddg = url.match(/[?&]uddg=([^&]+)/);
		if (uddg) url = decodeURIComponent(uddg[1]);
		if (url.startsWith("//")) url = `https:${url}`;
		if (/duckduckgo\.com\/y\.js/.test(url) || out.length >= n) return;
		out.push({ title: stripTags(m[2]), url, snippet: stripTags(snippets[i]?.[1] ?? "") });
	});
	if (out.length === 0) throw new Error("DuckDuckGo Lite returned no results");
	return out;
}

async function braveHtmlSearch(q: string, n: number, signal?: AbortSignal): Promise<SearchResult[]> {
	const res = await fetch(`https://search.brave.com/search?q=${encodeURIComponent(q)}&source=web`, {
		headers: { "User-Agent": DESKTOP_UA, "Accept-Language": "en-US,en;q=0.8" },
		signal,
	});
	if (!res.ok) throw new Error(`Brave ${res.status}`);
	const html = await res.text();
	const out: SearchResult[] = [];
	for (const block of html.split('data-type="web"').slice(1)) {
		const url = block.match(/<a[^>]*href="(https?:\/\/[^"]+)"/)?.[1];
		const title = block.match(/class="title search-snippet-title[^"]*"[^>]*>([\s\S]*?)<\/div>/)?.[1];
		if (!url || !title) continue;
		const snippet = block.match(/class="content [^"]*"[^>]*>([\s\S]*?)<\/div>/)?.[1] ?? "";
		out.push({ title: stripTags(title), url: decodeEntities(url), snippet: stripTags(snippet).replace(/<!---->/g, "") });
		if (out.length >= n) break;
	}
	if (out.length === 0) throw new Error("Brave returned no results");
	return out;
}

export async function webSearch(q: string, n: number, keys: SearchKeys, signal?: AbortSignal) {
	const attempts: [string, () => Promise<SearchResult[]>][] = [];
	if (keys.brave) attempts.push(["brave", () => braveSearch(q, n, keys.brave!, signal)]);
	if (keys.tavily) attempts.push(["tavily", () => tavilySearch(q, n, keys.tavily!, signal)]);
	attempts.push(
		["duckduckgo", () => duckSearch(q, n, signal)],
		["duckduckgo-lite", () => duckLiteSearch(q, n, signal)],
		["brave", () => braveHtmlSearch(q, n, signal)],
	);
	const errors: string[] = [];
	for (const [name, attempt] of attempts) {
		try {
			return { engine: name, results: await attempt() };
		} catch (e) {
			if (signal?.aborted) throw e;
			errors.push(`${name}: ${(e as Error).message}`);
		}
	}
	throw new Error(`Search failed (${errors.join("; ")})`);
}

// ---------------------------------------------------------------------------
// Fetch

export async function webFetch(url: string, signal?: AbortSignal) {
	if (!/^https?:\/\//i.test(url)) url = `https://${url}`;
	const res = await fetch(url, {
		headers: { "User-Agent": UA, Accept: "text/html,application/xhtml+xml,text/plain,application/json;q=0.9,*/*;q=0.5" },
		redirect: "follow",
		signal,
	});
	const type = res.headers.get("content-type") ?? "";
	const raw = await res.text();
	let text: string;
	let title = "";
	if (/html|xml/.test(type) || /^\s*<(!doctype|html)/i.test(raw)) {
		title = stripTags(raw.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1] ?? "");
		text = htmlToText(raw, res.url);
	} else {
		text = raw;
	}
	return { url: res.url, status: res.status, contentType: type, title, text };
}

/** Readable text with light markdown: headings, lists, links and code kept. */
export function htmlToText(html: string, base = ""): string {
	let s = html;
	// Prefer the main content when the page marks it.
	const main = s.match(/<(main|article)\b[\s\S]*?<\/\1>/i);
	if (main && main[0].length > 500) s = main[0];
	s = s.replace(/<(script|style|noscript|svg|head|template|iframe|nav|footer|form)\b[\s\S]*?<\/\1>/gi, "");
	s = s.replace(/<!--[\s\S]*?-->/g, "");
	s = s.replace(/<pre\b[^>]*>([\s\S]*?)<\/pre>/gi, (_, code) => `\n\n\`\`\`\n${decodeEntities(stripTags(code))}\n\`\`\`\n\n`);
	s = s.replace(/<code\b[^>]*>([\s\S]*?)<\/code>/gi, (_, code) => `\`${decodeEntities(stripTags(code))}\``);
	s = s.replace(/<h([1-6])\b[^>]*>([\s\S]*?)<\/h\1>/gi, (_, n, t) => `\n\n${"#".repeat(Number(n))} ${stripTags(t).trim()}\n\n`);
	s = s.replace(/<a\b[^>]*href="([^"#][^"]*)"[^>]*>([\s\S]*?)<\/a>/gi, (_, href, t) => {
		const label = stripTags(t).trim();
		if (!label) return "";
		let abs = decodeEntities(href);
		try {
			abs = new URL(abs, base).href;
		} catch {}
		return /^https?:/.test(abs) ? `[${label}](${abs})` : label;
	});
	s = s.replace(/<li\b[^>]*>/gi, "\n- ");
	s = s.replace(/<(br|hr)\b[^>]*>/gi, "\n");
	s = s.replace(/<\/(p|div|section|tr|table|ul|ol|blockquote|dd|dt|h\d)>/gi, "\n\n");
	s = s.replace(/<(td|th)\b[^>]*>/gi, " | ");
	s = decodeEntities(stripTags(s));
	return s
		.split("\n")
		.map((l) => l.replace(/[ \t ]+/g, " ").trimEnd())
		.join("\n")
		.replace(/\n{3,}/g, "\n\n")
		.trim();
}

function stripTags(s: string) {
	return decodeEntities(s.replace(/<[^>]+>/g, "")).replace(/\s+\n/g, "\n").trim();
}

function decodeEntities(s: string) {
	return s
		.replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
		.replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
		.replace(/&nbsp;/g, " ")
		.replace(/&lt;/g, "<")
		.replace(/&gt;/g, ">")
		.replace(/&quot;/g, '"')
		.replace(/&#39;|&apos;/g, "'")
		.replace(/&amp;/g, "&");
}

// ---------------------------------------------------------------------------
// Tool definitions for the pi SDK

const text = (t: string) => ({ content: [{ type: "text" as const, text: t }], details: undefined });

export function webTools(keys: () => SearchKeys) {
	return [
		{
			name: "web_search",
			label: "Web search",
			description:
				"Search the web. Use it to find install instructions, documentation, package names, API usage, and fixes for errors instead of guessing. Returns titles, URLs and snippets; follow up with web_fetch to read a page.",
			promptSnippet: "web_search: search the web for docs, install steps, and error fixes",
			promptGuidelines: [
				"When unsure how to install or use something, or an error is unfamiliar, use web_search and then web_fetch the most relevant result before acting.",
			],
			parameters: Type.Object({
				query: Type.String({ description: "Search query" }),
				count: Type.Optional(Type.Number({ description: "Number of results (default 8, max 20)" })),
			}),
			async execute(_id: string, params: { query: string; count?: number }, signal?: AbortSignal) {
				// Models trained on other search tools often send numResults/limit instead.
				const alt = params as any;
				const requested = Number(params.count ?? alt.numResults ?? alt.num_results ?? alt.limit ?? 8) || 8;
				const n = Math.min(Math.max(requested, 1), 20);
				const { engine, results } = await webSearch(params.query, n, keys(), signal);
				const body = results
					.map((r, i) => `${i + 1}. ${r.title}\n   ${r.url}${r.snippet ? `\n   ${r.snippet}` : ""}`)
					.join("\n\n");
				return text(`Results for "${params.query}" (${engine}):\n\n${body}`);
			},
		},
		{
			name: "web_fetch",
			label: "Fetch page",
			description:
				"Fetch a web page or raw file by URL and return its readable text (HTML is converted to markdown-like text). Long pages are paged: pass `offset` from the previous result to continue.",
			promptSnippet: "web_fetch: read a web page or raw file as text",
			parameters: Type.Object({
				url: Type.String({ description: "The URL to fetch" }),
				offset: Type.Optional(Type.Number({ description: "Character offset to continue from (default 0)" })),
				maxChars: Type.Optional(Type.Number({ description: "Characters to return (default 20000)" })),
			}),
			async execute(_id: string, params: { url: string; offset?: number; maxChars?: number }, signal?: AbortSignal) {
				const page = await webFetch(params.url, signal);
				const offset = Math.max(params.offset ?? 0, 0);
				const max = Math.min(Math.max(params.maxChars ?? 20000, 1000), 60000);
				const chunk = page.text.slice(offset, offset + max);
				const more = offset + max < page.text.length;
				const head = [
					`URL: ${page.url} (HTTP ${page.status})`,
					page.title ? `Title: ${page.title}` : null,
					`Showing ${offset}-${offset + chunk.length} of ${page.text.length} characters${more ? `; continue with offset ${offset + chunk.length}` : ""}`,
				]
					.filter(Boolean)
					.join("\n");
				return text(`${head}\n\n${chunk}`);
			},
		},
	];
}
