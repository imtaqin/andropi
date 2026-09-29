/**
 * Agent Skills (SKILL.md, https://agentskills.io) for pi: list, install from
 * skills.md, GitHub or a URL, remove, and seed the ones AndroPI ships with.
 * Skills live in <agentDir>/skills/<name>/, where pi discovers them.
 */

import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

export interface SkillInfo {
	name: string;
	description: string;
	path: string;
	source: string;
	builtin: boolean;
}

interface Origin {
	source: string;
	installedAt: number;
	builtin?: boolean;
}

const ORIGIN_FILE = ".andropi.json";

/** Curated collections searched first and shown when the query is empty. */
const COLLECTIONS = [
	{ repo: "anthropics/skills", label: "Anthropic" },
	{ repo: "badlogic/pi-skills", label: "pi skills" },
];

/** Installed on first launch from their own repositories. */
const STARTER = [
	"github.com/anthropics/skills/skills/frontend-design",
	"github.com/anthropics/skills/skills/canvas-design",
	"github.com/anthropics/skills/skills/theme-factory",
	"github.com/anthropics/skills/skills/web-artifacts-builder",
	"github.com/anthropics/skills/skills/webapp-testing",
	"github.com/anthropics/skills/skills/algorithmic-art",
	"github.com/anthropics/skills/skills/skill-creator",
	"github.com/anthropics/skills/skills/mcp-builder",
];

interface CatalogEntry {
	name: string;
	description: string;
	spec: string;
	origin: string;
}

export interface SearchHit extends CatalogEntry {
	installed: boolean;
	/** Caveat shown next to the result, e.g. skills.md skills that need their CLI. */
	note: string | null;
}

async function mapLimit<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
	const out: R[] = new Array(items.length);
	let next = 0;
	await Promise.all(
		Array.from({ length: Math.min(limit, items.length) }, async () => {
			while (next < items.length) {
				const i = next++;
				out[i] = await fn(items[i]);
			}
		}),
	);
	return out;
}

export class Skills {
	readonly dir: string;
	private readonly seededFile: string;

	constructor(
		agentDir: string,
		private readonly bundled: string,
		private readonly githubToken: () => string | undefined,
	) {
		this.dir = join(agentDir, "skills");
		this.seededFile = join(agentDir, "andropi", "seeded-skills.json");
		mkdirSync(this.dir, { recursive: true });
	}

	/** Copies bundled skills in once; ones the user removed stay removed. */
	seed() {
		if (!existsSync(this.bundled)) return;
		const seeded: string[] = existsSync(this.seededFile) ? JSON.parse(readFileSync(this.seededFile, "utf8")) : [];
		for (const name of readdirSync(this.bundled)) {
			const src = join(this.bundled, name);
			const dest = join(this.dir, name);
			if (!existsSync(join(src, "SKILL.md"))) continue;
			// Refresh our own copies on update; never resurrect a deleted one.
			const ours = existsSync(join(dest, ORIGIN_FILE)) && readOrigin(dest)?.builtin;
			if (seeded.includes(name) && !ours) continue;
			rmSync(dest, { recursive: true, force: true });
			cpSync(src, dest, { recursive: true });
			writeOrigin(dest, { source: "AndroPI", installedAt: Date.now(), builtin: true });
			if (!seeded.includes(name)) seeded.push(name);
		}
		mkdirSync(dirname(this.seededFile), { recursive: true });
		writeFileSync(this.seededFile, JSON.stringify(seeded));
	}

	list(): SkillInfo[] {
		const out: SkillInfo[] = [];
		const walk = (dir: string, depth: number) => {
			if (depth > 3) return;
			for (const name of readdirSync(dir)) {
				const path = join(dir, name);
				if (!statSync(path).isDirectory()) continue;
				const file = join(path, "SKILL.md");
				if (existsSync(file)) {
					const fm = frontmatter(readFileSync(file, "utf8"));
					const origin = readOrigin(path);
					out.push({
						name: fm.name || name,
						description: fm.description || "",
						path,
						source: origin?.source ?? "local",
						builtin: !!origin?.builtin,
					});
				} else {
					walk(path, depth + 1);
				}
			}
		};
		walk(this.dir, 0);
		return out.sort((a, b) => Number(b.builtin) - Number(a.builtin) || a.name.localeCompare(b.name));
	}

	remove(path: string) {
		if (!path.startsWith(this.dir + "/") && !path.startsWith(this.dir + "\\")) throw new Error("Not an installed skill");
		rmSync(path, { recursive: true, force: true });
	}

	/**
	 * Installs from any of:
	 *   skills.md/<name> or a bare name  -> https://skills.md/api/v1/skills/<name>/skill.md
	 *   owner/repo[/path] or a github.com URL (repo, tree or blob)
	 *   an https URL to a SKILL.md
	 * A GitHub location with several skills installs all of them.
	 */
	async install(spec: string, log: (line: string) => void): Promise<SkillInfo[]> {
		spec = spec.trim();
		if (!spec) throw new Error("Enter a skill name, GitHub repo or URL");
		const gh = parseGithub(spec);
		if (gh) return this.installGithub(gh, log);
		if (/^https?:\/\//.test(spec)) return [await this.installUrl(spec, log)];
		const name = spec.replace(/^(https?:\/\/)?skills\.md\/(skills\/)?/, "").replace(/\/+$/, "");
		return [await this.installUrl(`https://skills.md/api/v1/skills/${encodeURIComponent(name)}/skill.md`, log, `skills.md/${name}`)];
	}

	private async installUrl(url: string, log: (line: string) => void, source = url) {
		log(`Fetching ${url}`);
		const res = await fetch(url, { headers: { Accept: "text/markdown, text/plain, */*" } });
		if (!res.ok) throw new Error(`${res.status} ${res.statusText} for ${url}`);
		const body = await res.text();
		const fm = frontmatter(body);
		if (!fm.name || !fm.description) throw new Error("That file has no skill frontmatter (name and description)");
		const dest = join(this.dir, safeName(fm.name));
		rmSync(dest, { recursive: true, force: true });
		mkdirSync(dest, { recursive: true });
		writeFileSync(join(dest, "SKILL.md"), body);
		writeOrigin(dest, { source, installedAt: Date.now() });
		log(`Installed ${fm.name}`);
		return this.list().find((s) => s.path === dest)!;
	}

	private async gh(path: string) {
		const token = this.githubToken();
		const res = await fetch(`https://api.github.com${path}`, {
			headers: { Accept: "application/vnd.github+json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
		});
		if (!res.ok) throw new Error(`GitHub ${res.status}: ${((await res.json().catch(() => ({}))) as any).message ?? ""}`);
		return res.json() as Promise<any>;
	}

	// -------------------------------------------------------------------------
	// Starter pack: installed from their own repos (with their licenses) on
	// first launch, in the background. Removed ones are not reinstalled.

	async installStarter(log: (line: string) => void = () => {}) {
		const file = join(dirname(this.seededFile), "starter-skills.json");
		const done: string[] = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : [];
		for (const spec of STARTER) {
			if (done.includes(spec)) continue;
			try {
				await this.install(spec, log);
				done.push(spec);
				writeFileSync(file, JSON.stringify(done));
			} catch (e) {
				log(`Skipped ${spec}: ${(e as Error).message}`);
			}
		}
	}

	// -------------------------------------------------------------------------
	// Search

	private catalogFile() {
		return join(dirname(this.seededFile), "skill-catalog.json");
	}

	/** Name + description of every skill in the curated collections, cached for a day. */
	private async catalog(): Promise<CatalogEntry[]> {
		try {
			const cached = JSON.parse(readFileSync(this.catalogFile(), "utf8"));
			if (Date.now() - cached.at < 24 * 3600_000 && cached.entries?.length) return cached.entries;
		} catch {}
		const entries: CatalogEntry[] = [];
		for (const c of COLLECTIONS) {
			const gh = parseGithub(c.repo)!;
			try {
				const { files, ref } = await this.githubTree(gh);
				const dirs = files.filter((f) => f.endsWith("/SKILL.md")).map((f) => f.slice(0, -"/SKILL.md".length));
				const metas = await mapLimit(dirs, 8, async (dir) => {
					const fm = frontmatter(await rawGithub(gh, ref, `${dir}/SKILL.md`).catch(() => ""));
					return {
						name: fm.name || dir.split("/").pop()!,
						description: fm.description || "",
						spec: `github.com/${gh.owner}/${gh.repo}/${dir}`,
						origin: c.label,
					};
				});
				entries.push(...metas);
			} catch {
				// One unreachable collection should not break search.
			}
		}
		mkdirSync(dirname(this.catalogFile()), { recursive: true });
		writeFileSync(this.catalogFile(), JSON.stringify({ at: Date.now(), entries }));
		return entries;
	}

	/**
	 * Searches the curated collections, skills.md and (when signed in) all of
	 * GitHub. With an empty query, returns the curated collections.
	 */
	async search(query: string): Promise<SearchHit[]> {
		const q = query.trim().toLowerCase();
		const terms = q.split(/\s+/).filter(Boolean);
		const installedSources = new Set(this.list().map((s) => s.source));
		const installedNames = new Set(this.list().map((s) => s.name));
		const mark = (h: Omit<SearchHit, "installed">): SearchHit => ({
			...h,
			installed: installedSources.has(h.spec) || installedNames.has(h.name),
		});

		const curated = (async () => {
			const all = await this.catalog();
			if (!terms.length) return all.map((e) => mark({ ...e, note: null }));
			return all
				.map((e) => {
					const hay = `${e.name} ${e.description}`.toLowerCase();
					const score = terms.reduce((s, t) => s + (e.name.toLowerCase().includes(t) ? 3 : hay.includes(t) ? 1 : -99), 0);
					return { e, score };
				})
				.filter((x) => x.score > 0)
				.sort((a, b) => b.score - a.score)
				.map(({ e }) => mark({ ...e, note: null }));
		})();

		const skillsMd = (async (): Promise<SearchHit[]> => {
			if (!terms.length) return [];
			const res = await fetch(`https://skills.md/api/v1/skills/search?q=${encodeURIComponent(q)}`, {
				headers: { Accept: "application/json" },
				signal: AbortSignal.timeout(10_000),
			});
			if (!res.ok) return [];
			const list = (await res.json()) as any[];
			return list.slice(0, 15).map((s) =>
				mark({
					name: s.name,
					description: s.description ?? "",
					spec: `skills.md/${s.name}`,
					origin: "skills.md",
					note: s.pricing?.tier === "premium" ? "Premium · runs on skills.md" : "Uses the skills.md CLI",
				}),
			);
		})().catch(() => []);

		const github = (async (): Promise<SearchHit[]> => {
			const token = this.githubToken();
			if (!terms.length || !token) return [];
			const res = await this.gh(`/search/code?q=${encodeURIComponent(`${q} filename:SKILL.md`)}&per_page=20`);
			const seen = new Set<string>();
			const hits = (res.items as any[])
				.filter((i) => i.name === "SKILL.md")
				.map((i) => {
					const dir = i.path.includes("/") ? i.path.slice(0, i.path.lastIndexOf("/")) : "";
					return { repo: i.repository.full_name as string, dir, stars: i.repository.stargazers_count ?? 0 };
				})
				.filter((h) => !COLLECTIONS.some((c) => c.repo === h.repo) && !seen.has(`${h.repo}/${h.dir}`) && seen.add(`${h.repo}/${h.dir}`))
				.slice(0, 10);
			// Code search results carry no description; read it from each SKILL.md.
			return mapLimit(hits, 5, async (h) => {
				const [owner, repo] = h.repo.split("/");
				const md = await rawGithub({ owner, repo }, "HEAD", `${h.dir ? `${h.dir}/` : ""}SKILL.md`).catch(() => "");
				const fm = frontmatter(md);
				return mark({
					name: fm.name || h.dir.split("/").pop() || repo,
					description: fm.description || "",
					spec: `github.com/${h.repo}${h.dir ? `/${h.dir}` : ""}`,
					origin: h.repo,
					note: null,
				});
			});
		})().catch(() => []);

		const [a, b, c] = await Promise.all([curated, skillsMd, github]);
		return [...a, ...c, ...b];
	}

	/** Every skill folder in a GitHub location, for browsing before installing. */
	async browse(spec: string) {
		const gh = parseGithub(spec);
		if (!gh) throw new Error("Use owner/repo or a github.com link");
		const { files, ref } = await this.githubTree(gh);
		const installed = new Set(this.list().map((s) => s.source));
		return files
			.filter((f) => f.endsWith("/SKILL.md") || f === "SKILL.md")
			.map((f) => {
				const dir = f === "SKILL.md" ? "" : f.slice(0, -"/SKILL.md".length);
				const source = `github.com/${gh.owner}/${gh.repo}${dir ? `/${dir}` : ""}`;
				return { name: dir.split("/").pop() || gh.repo, path: dir, source, ref, installed: installed.has(source) };
			})
			.filter((s) => !gh.path || s.path === gh.path || s.path.startsWith(`${gh.path}/`));
	}

	private async githubTree(gh: GithubSpec) {
		const ref = gh.ref ?? (await this.gh(`/repos/${gh.owner}/${gh.repo}`)).default_branch;
		const tree = await this.gh(`/repos/${gh.owner}/${gh.repo}/git/trees/${encodeURIComponent(ref)}?recursive=1`);
		const files = (tree.tree as any[]).filter((e) => e.type === "blob").map((e) => e.path as string);
		return { files, ref };
	}

	private async installGithub(gh: GithubSpec, log: (line: string) => void) {
		log(`Reading github.com/${gh.owner}/${gh.repo}…`);
		const { files, ref } = await this.githubTree(gh);
		const base = gh.path?.replace(/\/SKILL\.md$/, "") ?? "";
		const skillDirs = files
			.filter((f) => f.endsWith("SKILL.md") && (f === "SKILL.md" || f.endsWith("/SKILL.md")))
			.map((f) => (f === "SKILL.md" ? "" : f.slice(0, -"/SKILL.md".length)))
			.filter((d) => !base || d === base || d.startsWith(`${base}/`));
		if (skillDirs.length === 0) throw new Error("No SKILL.md found there");
		const installed: SkillInfo[] = [];
		for (const dir of skillDirs) {
			const prefix = dir ? `${dir}/` : "";
			// Skip files that belong to a nested skill of their own.
			const own = files.filter(
				(f) => f.startsWith(prefix) && !skillDirs.some((o) => o !== dir && o.startsWith(prefix) && f.startsWith(`${o}/`)),
			);
			const skillMd = await rawGithub(gh, ref, `${prefix}SKILL.md`);
			const fm = frontmatter(skillMd);
			const name = safeName(fm.name || dir.split("/").pop() || gh.repo);
			log(`Installing ${name} (${own.length} files)`);
			const dest = join(this.dir, name);
			rmSync(dest, { recursive: true, force: true });
			for (const f of own) {
				const rel = f.slice(prefix.length);
				if (rel.split("/").some((part) => part === ".." || part.startsWith(".git"))) continue;
				const target = join(dest, rel);
				mkdirSync(dirname(target), { recursive: true });
				writeFileSync(target, rel === "SKILL.md" ? skillMd : Buffer.from(await rawGithubBytes(gh, ref, f)));
			}
			writeOrigin(dest, { source: `github.com/${gh.owner}/${gh.repo}${dir ? `/${dir}` : ""}`, installedAt: Date.now() });
			installed.push(this.list().find((s) => s.path === dest)!);
		}
		log(`Installed ${installed.map((s) => s.name).join(", ")}`);
		return installed;
	}
}

// ---------------------------------------------------------------------------

interface GithubSpec {
	owner: string;
	repo: string;
	ref?: string;
	path?: string;
}

function parseGithub(spec: string): GithubSpec | null {
	const url = spec.match(/^(?:https?:\/\/)?github\.com\/([^/]+)\/([^/#?]+)(?:\/(?:tree|blob)\/([^/]+)(?:\/(.+?))?)?\/?$/);
	if (url) return { owner: url[1], repo: url[2].replace(/\.git$/, ""), ref: url[3], path: url[4] };
	// github.com/owner/repo/some/folder (our own install specs; default branch).
	const plain = spec.match(/^(?:https?:\/\/)?github\.com\/([^/]+)\/([^/#?]+)\/(.+?)\/?$/);
	if (plain) return { owner: plain[1], repo: plain[2].replace(/\.git$/, ""), path: plain[3] };
	const short = spec.match(/^([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)(?:\/(.+?))?\/?$/);
	if (short && !spec.includes(":") && !spec.startsWith("skills.md")) return { owner: short[1], repo: short[2], path: short[3] };
	return null;
}

async function rawGithubBytes(gh: GithubSpec, ref: string, path: string) {
	const res = await fetch(`https://raw.githubusercontent.com/${gh.owner}/${gh.repo}/${ref}/${path.split("/").map(encodeURIComponent).join("/")}`);
	if (!res.ok) throw new Error(`Could not download ${path} (${res.status})`);
	return res.arrayBuffer();
}

async function rawGithub(gh: GithubSpec, ref: string, path: string) {
	return new TextDecoder().decode(await rawGithubBytes(gh, ref, path));
}

function frontmatter(md: string): Record<string, string> {
	const m = md.match(/^﻿?---\r?\n([\s\S]*?)\r?\n---/);
	const out: Record<string, string> = {};
	if (!m) return out;
	let key: string | null = null;
	for (const line of m[1].split(/\r?\n/)) {
		const kv = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
		if (kv) {
			key = kv[1];
			out[key] = kv[2].replace(/^["']|["']$/g, "").replace(/^[>|]-?$/, "");
		} else if (key && /^\s+\S/.test(line)) {
			out[key] = `${out[key]} ${line.trim()}`.trim();
		}
	}
	return out;
}

function safeName(name: string) {
	return name.toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 64) || "skill";
}

function readOrigin(dir: string): Origin | null {
	try {
		return JSON.parse(readFileSync(join(dir, ORIGIN_FILE), "utf8"));
	} catch {
		return null;
	}
}

function writeOrigin(dir: string, origin: Origin) {
	writeFileSync(join(dir, ORIGIN_FILE), JSON.stringify(origin));
}
