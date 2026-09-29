/**
 * Accounts, repositories, SSH and deploy targets for the AndroPI app.
 *
 * Credentials live in <agentDir>/andropi/integrations.json (app-private
 * storage) and are exported into the host's environment, so the agent's own
 * shell can use them too (git push, curl the GitHub API, deploy).
 */

import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { basename, join, relative } from "node:path";
import { configureDns, type DnsMode } from "./dns.js";
import { readSecureJson, writeSecureJson } from "./secure.js";

export interface SshHost {
	id: string;
	name: string;
	host: string;
	port: number;
	user: string;
	/** Default remote directory for deploys. */
	path?: string;
}

interface Store {
	github?: { token: string; login: string; name: string | null; email: string; avatarUrl: string };
	vercel?: { token: string; username: string };
	sshHosts: SshHost[];
	settings?: AppSettings;
}

export interface AppSettings {
	dns: DnsMode;
	dnsUrl?: string;
	braveKey?: string;
	tavilyKey?: string;
	/** Agent shell in the Linux container; unset means on whenever it is installed. */
	containerShell?: boolean;
	/** When the agent must ask before acting (see guard.ts). */
	approvalMode?: "ask_all" | "ask_risky" | "auto";
	/** Tried in order when the current model errors out (rate limits, outages). */
	fallbackModels?: { provider: string; model: string }[];
	/** Daily spend cap in USD; prompts are refused once reached. 0 or unset = none. */
	dailyBudget?: number;
}

const DEFAULT_SETTINGS: AppSettings = { dns: "cloudflare" };

/** Client ID of the AndroPI GitHub OAuth App (device flow enabled). Public by design; no secret is used. */
const GITHUB_CLIENT_ID = process.env.ANDROPI_GITHUB_CLIENT_ID ?? "Ov23lidVAetnaasSTbSU";

/** Line output, plus an optional channel for structured CI progress. */
export type Log = ((line: string) => void) & { ci?: (snapshot: CiSnapshot) => void };

export interface CiStep {
	name: string;
	status: string;
	conclusion: string | null;
}
export interface CiJob extends CiStep {
	steps: CiStep[];
}
export interface CiRun extends CiStep {
	id: string;
	url: string | null;
	jobs: CiJob[];
}
export interface CiSnapshot {
	provider: "github" | "vercel";
	runs: CiRun[];
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const FAILED = new Set(["failure", "cancelled", "timed_out", "startup_failure", "action_required"]);

export class Integrations {
	private store: Store = { sshHosts: [] };
	private readonly file: string;
	private readonly home: string;

	constructor(
		agentDir: string,
		private readonly workspace: string,
	) {
		const dir = join(agentDir, "andropi");
		mkdirSync(dir, { recursive: true });
		this.file = join(dir, "integrations.json");
		this.home = process.env.HOME ?? agentDir;
		// Encrypted at rest when the Keystore key is available (see secure.ts).
		this.store = { sshHosts: [], ...readSecureJson<Partial<Store>>(this.file, {}) };
		this.exportEnv();
		this.applySettings();
	}

	get settings(): AppSettings {
		return { ...DEFAULT_SETTINGS, ...this.store.settings };
	}

	/** Keys are write-only from the app's point of view: it only learns whether one is set. */
	publicSettings() {
		const { dns, dnsUrl, braveKey, tavilyKey, approvalMode, fallbackModels, dailyBudget } = this.settings;
		return {
			dns,
			dnsUrl: dnsUrl ?? null,
			braveKey: !!braveKey,
			tavilyKey: !!tavilyKey,
			approvalMode: approvalMode ?? "ask_risky",
			fallbackModels: fallbackModels ?? [],
			dailyBudget: dailyBudget ?? 0,
		};
	}

	updateSettings(patch: Partial<AppSettings>) {
		const next: AppSettings = { ...this.settings };
		for (const [k, v] of Object.entries(patch)) {
			if (v === undefined) continue;
			(next as any)[k] = v === "" || v === null ? undefined : v;
		}
		this.store.settings = next;
		this.save();
		this.applySettings();
		return this.publicSettings();
	}

	private applySettings() {
		const s = this.settings;
		configureDns(s.dns, s.dnsUrl);
	}

	searchKeys() {
		return { brave: this.settings.braveKey, tavily: this.settings.tavilyKey };
	}

	private save() {
		writeSecureJson(this.file, this.store);
		this.exportEnv();
	}

	/** Tokens become env vars for everything the agent runs. */
	private exportEnv() {
		const gh = this.store.github?.token;
		for (const key of ["GITHUB_TOKEN", "GH_TOKEN"]) {
			if (gh) process.env[key] = gh;
			else delete process.env[key];
		}
		if (this.store.vercel) process.env.VERCEL_TOKEN = this.store.vercel.token;
		else delete process.env.VERCEL_TOKEN;
	}

	summary() {
		const { github, vercel, sshHosts } = this.store;
		const pub = join(this.home, ".ssh", "id_ed25519.pub");
		return {
			github: github ? { login: github.login, name: github.name, avatarUrl: github.avatarUrl } : null,
			vercel: vercel ? { username: vercel.username } : null,
			ssh: { publicKey: existsSync(pub) ? readFileSync(pub, "utf8").trim() : null, hosts: sshHosts },
		};
	}

	// -------------------------------------------------------------------------
	// GitHub

	private async github(path: string, init: RequestInit = {}, token = this.store.github?.token) {
		if (!token) throw new Error("Not signed in to GitHub");
		const res = await fetch(`https://api.github.com${path}`, {
			...init,
			headers: {
				Accept: "application/vnd.github+json",
				Authorization: `Bearer ${token}`,
				"X-GitHub-Api-Version": "2022-11-28",
				...(init.body ? { "Content-Type": "application/json" } : {}),
				...init.headers,
			},
		});
		const body = res.status === 204 ? null : await res.json().catch(() => null);
		if (!res.ok) {
			const message = (body as any)?.message ?? res.statusText;
			const err = new Error(`GitHub: ${message} (${res.status})`) as Error & { status?: number };
			err.status = res.status;
			throw err;
		}
		return body as any;
	}

	/** GitHub REST call with the stored token, for other modules. */
	githubApi(path: string, init: RequestInit = {}) {
		return this.github(path, init);
	}

	async githubLogin(token: string) {
		token = token.trim();
		const user = await this.github("/user", {}, token);
		this.store.github = {
			token,
			login: user.login,
			name: user.name ?? null,
			email: user.email ?? `${user.id}+${user.login}@users.noreply.github.com`,
			avatarUrl: user.avatar_url,
		};
		this.save();
		await this.configureGit();
		return this.summary();
	}

	/**
	 * GitHub device flow: the user types a short code at github.com/login/device
	 * instead of creating and pasting a token. Needs the Client ID of an OAuth
	 * App with "Enable Device Flow" ticked (the ID is public; there is no secret).
	 */
	async githubDeviceStart() {
		if (!GITHUB_CLIENT_ID) throw new Error("GitHub device login is not set up in this build (missing OAuth Client ID). Use a token instead.");
		const r = await this.githubOAuth("/login/device/code", { client_id: GITHUB_CLIENT_ID, scope: "repo workflow read:org" });
		if (r.error || !r.device_code) {
			// "device_flow_disabled" means the OAuth App exists but the Device Flow box is not ticked.
			throw new Error((r.error_description as string) ?? (r.error as string) ?? "GitHub did not return a device code");
		}
		return {
			deviceCode: r.device_code as string,
			userCode: r.user_code as string,
			verificationUri: (r.verification_uri as string) ?? "https://github.com/login/device",
			expiresIn: (r.expires_in as number) ?? 900,
			interval: (r.interval as number) ?? 5,
		};
	}

	/** One poll of the device flow. The app calls this every `interval` seconds until it is not pending. */
	async githubDevicePoll(deviceCode: string) {
		const r = await this.githubOAuth("/login/oauth/access_token", {
			client_id: GITHUB_CLIENT_ID,
			device_code: deviceCode,
			grant_type: "urn:ietf:params:oauth:grant-type:device_code",
		});
		if (r.access_token) return { status: "done", state: await this.githubLogin(r.access_token as string) };
		switch (r.error) {
			case "authorization_pending":
				return { status: "pending" };
			case "slow_down":
				return { status: "slow_down", interval: r.interval as number | undefined };
			case "expired_token":
				return { status: "expired" };
			case "access_denied":
				return { status: "denied" };
			default:
				throw new Error((r.error_description as string) ?? (r.error as string) ?? "GitHub login failed");
		}
	}

	private async githubOAuth(path: string, body: Record<string, string>) {
		const res = await fetch(`https://github.com${path}`, {
			method: "POST",
			headers: { Accept: "application/json", "Content-Type": "application/json", "User-Agent": "AndroPI" },
			body: JSON.stringify(body),
		});
		const text = await res.text();
		let json: Record<string, unknown>;
		try {
			json = JSON.parse(text);
		} catch {
			throw new Error(`GitHub answered ${res.status}: ${text.slice(0, 200)}`);
		}
		if (!res.ok && !json.error) throw new Error(`GitHub answered ${res.status}`);
		return json;
	}

	async githubLogout() {
		delete this.store.github;
		this.save();
		await this.configureGit();
		return this.summary();
	}

	/**
	 * Commit identity plus an auth header for github.com. A header rather than
	 * a credential helper: helpers run through git's compiled-in shell path,
	 * which does not exist on Android.
	 */
	private async configureGit() {
		const gh = this.store.github;
		const key = "http.https://github.com/.extraheader";
		await run("git", ["config", "--global", "--unset-all", key], { cwd: this.home }).catch(() => {});
		if (!gh) return;
		const basic = Buffer.from(`x-access-token:${gh.token}`).toString("base64");
		await run("git", ["config", "--global", "--add", key, `Authorization: Basic ${basic}`], { cwd: this.home });
		await run("git", ["config", "--global", "user.name", gh.name ?? gh.login], { cwd: this.home });
		await run("git", ["config", "--global", "user.email", gh.email], { cwd: this.home });
		await run("git", ["config", "--global", "init.defaultBranch", "main"], { cwd: this.home });
	}

	async repos() {
		const list: any[] = [];
		for (let page = 1; page <= 5; page++) {
			const batch = await this.github(
				`/user/repos?per_page=100&page=${page}&sort=pushed&affiliation=owner,collaborator,organization_member`,
			);
			list.push(...batch);
			if (batch.length < 100) break;
		}
		return list.map((r) => ({
			fullName: r.full_name,
			name: r.name,
			owner: r.owner?.login,
			private: r.private,
			description: r.description ?? null,
			language: r.language ?? null,
			stars: r.stargazers_count ?? 0,
			pushedAt: r.pushed_at,
			defaultBranch: r.default_branch,
			cloned: existsSync(join(this.workspace, r.name, ".git")),
		}));
	}

	async clone(fullName: string, log: Log) {
		const name = fullName.split("/").pop()!;
		const dest = join(this.workspace, name);
		if (existsSync(join(dest, ".git"))) {
			log(`${name} is already cloned`);
			return { path: dest };
		}
		await run("git", ["clone", "--progress", `https://github.com/${fullName}.git`, dest], {
			cwd: this.workspace,
			log,
		});
		return { path: dest };
	}

	// -------------------------------------------------------------------------
	// Projects in the workspace

	async projects() {
		const out = [];
		for (const name of readdirSync(this.workspace)) {
			const dir = join(this.workspace, name);
			if (name.startsWith(".") || !statSync(dir).isDirectory()) continue;
			const git = existsSync(join(dir, ".git"));
			let branch: string | null = null;
			let remote: string | null = null;
			let dirty = false;
			if (git) {
				branch = (await run("git", ["branch", "--show-current"], { cwd: dir }).catch(() => "")).trim() || null;
				remote = (await run("git", ["remote", "get-url", "origin"], { cwd: dir }).catch(() => "")).trim() || null;
				dirty = (await run("git", ["status", "--porcelain"], { cwd: dir }).catch(() => "")).trim().length > 0;
			}
			out.push({ name, path: dir, git, branch, remote, dirty, modified: statSync(dir).mtimeMs });
		}
		return out.sort((a, b) => b.modified - a.modified);
	}

	// -------------------------------------------------------------------------
	// SSH

	async sshKey() {
		const key = join(this.home, ".ssh", "id_ed25519");
		mkdirSync(join(this.home, ".ssh"), { recursive: true, mode: 0o700 });
		if (!existsSync(key)) {
			await run("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "andropi", "-f", key], { cwd: this.home });
		}
		return readFileSync(`${key}.pub`, "utf8").trim();
	}

	saveSshHost(host: Partial<SshHost>) {
		if (!host.host || !host.user) throw new Error("Host and user are required");
		const entry: SshHost = {
			id: host.id ?? randomUUID(),
			name: sanitizeAlias(host.name || host.host),
			host: host.host.trim(),
			port: Number(host.port) || 22,
			user: host.user.trim(),
			path: host.path?.trim() || undefined,
		};
		const i = this.store.sshHosts.findIndex((h) => h.id === entry.id);
		if (i >= 0) this.store.sshHosts[i] = entry;
		else this.store.sshHosts.push(entry);
		this.save();
		this.writeSshConfig();
		return this.summary();
	}

	deleteSshHost(id: string) {
		this.store.sshHosts = this.store.sshHosts.filter((h) => h.id !== id);
		this.save();
		this.writeSshConfig();
		return this.summary();
	}

	/** Saved hosts become aliases in ~/.ssh/config so `ssh <name>` just works. */
	private writeSshConfig() {
		const file = join(this.home, ".ssh", "config");
		const begin = "# >>> andropi hosts (managed) >>>";
		const end = "# <<< andropi hosts <<<";
		let current = existsSync(file) ? readFileSync(file, "utf8") : "";
		const a = current.indexOf(begin);
		const b = current.indexOf(end);
		if (a >= 0 && b > a) current = current.slice(0, a) + current.slice(b + end.length);
		const key = join(this.home, ".ssh", "id_ed25519");
		const blocks = this.store.sshHosts.map(
			(h) =>
				`Host ${h.name}\n  HostName ${h.host}\n  User ${h.user}\n  Port ${h.port}\n  IdentityFile ${key}\n  UserKnownHostsFile ${join(this.home, ".ssh", "known_hosts")}\n  StrictHostKeyChecking accept-new\n`,
		);
		const managed = blocks.length ? `${begin}\n${blocks.join("\n")}${end}\n` : "";
		mkdirSync(join(this.home, ".ssh"), { recursive: true, mode: 0o700 });
		writeFileSync(file, `${managed}${current.trim() ? `\n${current.trim()}\n` : ""}`, { mode: 0o600 });
	}

	async sshTest(id: string, log: Log) {
		const h = this.host(id);
		await run("ssh", ["-F", join(this.home, ".ssh", "config"), "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", h.name, "echo connected: $(uname -sn)"], {
			cwd: this.home,
			log,
		});
		return { ok: true };
	}

	private host(id: string) {
		const h = this.store.sshHosts.find((x) => x.id === id);
		if (!h) throw new Error("Unknown SSH host");
		return h;
	}

	// -------------------------------------------------------------------------
	// Vercel

	private async vercel(path: string, init: RequestInit = {}, token = this.store.vercel?.token) {
		if (!token) throw new Error("Not connected to Vercel");
		const res = await fetch(`https://api.vercel.com${path}`, {
			...init,
			headers: { Authorization: `Bearer ${token}`, ...init.headers },
		});
		const body = await res.json().catch(() => null);
		if (!res.ok) throw new Error(`Vercel: ${(body as any)?.error?.message ?? res.statusText} (${res.status})`);
		return body as any;
	}

	async vercelLogin(token: string) {
		token = token.trim();
		const { user } = await this.vercel("/v2/user", {}, token);
		this.store.vercel = { token, username: user.username ?? user.email };
		this.save();
		return this.summary();
	}

	vercelLogout() {
		delete this.store.vercel;
		this.save();
		return this.summary();
	}

	// -------------------------------------------------------------------------
	// Deploy

	async deploy(target: string, dir: string, options: Record<string, any>, log: Log) {
		if (!existsSync(dir)) throw new Error(`No such folder: ${dir}`);
		switch (target) {
			case "vercel":
				return this.deployVercel(dir, options, log);
			case "github_pages":
				return this.deployPages(dir, options, log);
			case "ssh":
				return this.deploySsh(dir, options, log);
			default:
				throw new Error(`Unknown deploy target: ${target}`);
		}
	}

	private async deployVercel(dir: string, options: Record<string, any>, log: Log) {
		const files = walk(dir);
		if (files.length === 0) throw new Error("Nothing to deploy: the folder is empty");
		log(`Uploading ${files.length} files…`);
		const manifest = [];
		let done = 0;
		for (const rel of files) {
			const data = readFileSync(join(dir, rel));
			const sha = createHash("sha1").update(data).digest("hex");
			await this.vercel("/v2/files", {
				method: "POST",
				headers: { "Content-Type": "application/octet-stream", "x-vercel-digest": sha },
				body: data,
			});
			manifest.push({ file: rel.split("\\").join("/"), sha, size: data.length });
			done++;
			if (done % 10 === 0 || done === files.length) log(`  ${done}/${files.length}`);
		}
		const name = sanitizeProject(options.project || basename(dir));
		log(`Creating deployment for ${name}…`);
		let dep = await this.vercel("/v13/deployments?skipAutoDetectionConfirmation=1", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ name, files: manifest, target: options.preview ? undefined : "production" }),
		});
		const inspector: string | null = dep.inspectorUrl ?? null;
		const report = (state: string) => {
			const done = ["READY", "ERROR", "CANCELED"].includes(state);
			log.ci?.({
				provider: "vercel",
				runs: [
					{
						id: dep.id,
						name: `Vercel · ${name}`,
						status: done ? "completed" : state === "QUEUED" || state === "INITIALIZING" ? "queued" : "in_progress",
						conclusion: done ? (state === "READY" ? "success" : "failure") : null,
						url: inspector,
						jobs: [],
					},
				],
			});
		};
		report(dep.readyState);
		const events = new AbortController();
		void this.streamVercelBuild(dep.id, log, events.signal);
		const started = Date.now();
		try {
			while (!["READY", "ERROR", "CANCELED"].includes(dep.readyState) && Date.now() - started < 15 * 60_000) {
				await sleep(3000);
				dep = await this.vercel(`/v13/deployments/${dep.id}`);
				report(dep.readyState);
			}
		} finally {
			// Let the last build lines land before closing the stream.
			await sleep(1000);
			events.abort();
		}
		if (dep.readyState !== "READY") throw new Error(`Deployment ${dep.readyState?.toLowerCase() ?? "timed out"}`);
		const url = `https://${dep.alias?.[0] ?? dep.url}`;
		log(`Live at ${url}`);
		return { url };
	}

	/** Follows a deployment's build output (the same log the Vercel dashboard shows). */
	private async streamVercelBuild(id: string, log: Log, signal: AbortSignal) {
		try {
			const res = await fetch(`https://api.vercel.com/v3/deployments/${id}/events?follow=1&builds=1`, {
				headers: { Authorization: `Bearer ${this.store.vercel?.token}` },
				signal,
			});
			if (!res.ok || !res.body) return;
			const decoder = new TextDecoder();
			let buffer = "";
			for await (const chunk of res.body as any as AsyncIterable<Uint8Array>) {
				buffer += decoder.decode(chunk, { stream: true });
				let nl: number;
				while ((nl = buffer.indexOf("\n")) >= 0) {
					const line = buffer.slice(0, nl).trim();
					buffer = buffer.slice(nl + 1);
					if (!line) continue;
					try {
						const ev = JSON.parse(line);
						const text = ev.payload?.text ?? ev.text;
						if (typeof text === "string" && text.trim()) log(`│ ${text.trimEnd()}`);
					} catch {
						// Keep-alive or partial line.
					}
				}
			}
		} catch {
			// Aborted when the deployment settles, or the stream is unavailable; state polling still reports.
		}
	}

	/**
	 * Waits for every GitHub Actions run on `sha` (Pages' own build plus any
	 * workflows the repo has), reporting jobs and steps as they progress.
	 * Throws with the failing job's log tail if one fails.
	 */
	async watchActions(slug: string, sha: string, log: Log) {
		const deadline = Date.now() + 20 * 60_000;
		const appearBy = Date.now() + 90_000;
		const announced = new Map<string, string>();
		while (Date.now() < deadline) {
			const { workflow_runs: list = [] } = await this.github(
				`/repos/${slug}/actions/runs?head_sha=${sha}&per_page=20`,
			).catch(() => ({ workflow_runs: [] }));
			if (list.length === 0) {
				if (Date.now() > appearBy) {
					log("No CI runs were started for this commit");
					return;
				}
				await sleep(4000);
				continue;
			}
			const runs: CiRun[] = [];
			for (const r of list) {
				const { jobs = [] } = await this.github(`/repos/${slug}/actions/runs/${r.id}/jobs`).catch(() => ({ jobs: [] }));
				runs.push({
					id: String(r.id),
					name: r.name ?? r.display_title ?? "workflow",
					status: r.status,
					conclusion: r.conclusion ?? null,
					url: r.html_url ?? null,
					jobs: jobs.map((j: any) => ({
						id: j.id,
						name: j.name,
						status: j.status,
						conclusion: j.conclusion ?? null,
						steps: (j.steps ?? []).map((s: any) => ({ name: s.name, status: s.status, conclusion: s.conclusion ?? null })),
					})),
				});
				for (const j of jobs) {
					const state = j.conclusion ?? j.status;
					const key = `${r.id}/${j.id}`;
					if (announced.get(key) !== state) {
						announced.set(key, state);
						log(`${r.name} › ${j.name}: ${state.replace(/_/g, " ")}`);
					}
				}
			}
			log.ci?.({ provider: "github", runs });
			if (runs.every((r) => r.status === "completed")) {
				const failed = list.filter((r: any) => FAILED.has(r.conclusion));
				for (const r of failed) {
					const run = runs.find((x) => x.id === String(r.id))!;
					for (const j of run.jobs as any[]) {
						if (!FAILED.has(j.conclusion)) continue;
						const tail = await this.jobLogTail(slug, j.id);
						log(`── ${r.name} › ${j.name} failed ──`);
						for (const line of tail) log(line);
					}
				}
				if (failed.length) throw new Error(`CI failed: ${failed.map((r: any) => r.name).join(", ")}`);
				return;
			}
			await sleep(4000);
		}
		log("Stopped waiting for CI after 20 minutes");
	}

	/** CI for the latest commit of a project folder with a GitHub remote. */
	async watchProject(dir: string, log: Log) {
		const remote = (await run("git", ["remote", "get-url", "origin"], { cwd: dir }).catch(() => "")).trim();
		const slug = parseGithubSlug(remote);
		if (!slug) throw new Error("This folder has no GitHub remote");
		const sha = (await run("git", ["rev-parse", "HEAD"], { cwd: dir })).trim();
		log(`CI for ${slug}@${sha.slice(0, 7)}`);
		await this.watchActions(slug, sha, log);
		return { url: null };
	}

	private async jobLogTail(slug: string, jobId: number, lines = 30) {
		try {
			const res = await fetch(`https://api.github.com/repos/${slug}/actions/jobs/${jobId}/logs`, {
				headers: { Authorization: `Bearer ${this.store.github?.token}`, Accept: "application/vnd.github+json" },
			});
			if (!res.ok) return [`(logs unavailable: ${res.status})`];
			const text = await res.text();
			// Drop the timestamp prefix GitHub puts on every line.
			return text
				.split("\n")
				.map((l) => l.replace(/^\d{4}-\d\d-\d\dT[\d:.]+Z\s?/, "").trimEnd())
				.filter(Boolean)
				.slice(-lines);
		} catch {
			return ["(logs unavailable)"];
		}
	}

	private async deployPages(dir: string, options: Record<string, any>, log: Log) {
		const gh = this.store.github;
		if (!gh) throw new Error("Sign in to GitHub first");
		const git = (args: string[]) => run("git", args, { cwd: dir, log });
		const quiet = (args: string[]) => run("git", args, { cwd: dir });

		let root = (await quiet(["rev-parse", "--show-toplevel"]).catch(() => "")).trim();
		if (!root) {
			log("Initialising a git repository…");
			await git(["init", "-b", "main"]);
			root = dir;
		}
		let remote = (await quiet(["remote", "get-url", "origin"]).catch(() => "")).trim();
		let slug = parseGithubSlug(remote);
		if (!slug) {
			const name = sanitizeRepo(options.repo || basename(root));
			log(`Creating GitHub repository ${gh.login}/${name}…`);
			const repo = await this.github("/user/repos", {
				method: "POST",
				body: JSON.stringify({ name, private: false, description: "Deployed from AndroPI" }),
			}).catch(async (e) => {
				if ((e as any).status === 422) return this.github(`/repos/${gh.login}/${name}`);
				throw e;
			});
			slug = repo.full_name as string;
			remote = `https://github.com/${slug}.git`;
			await quiet(["remote", "remove", "origin"]).catch(() => {});
			await git(["remote", "add", "origin", remote]);
		}

		if (options.commit !== false) {
			await git(["add", "-A"]);
			const staged = (await quiet(["diff", "--cached", "--name-only"])).trim();
			const hasHead = await quiet(["rev-parse", "--verify", "HEAD"]).then(() => true, () => false);
			if (staged || !hasHead) {
				await git(["commit", "--allow-empty", "-m", options.message || "Deploy from AndroPI"]);
			} else {
				log("No changes to commit");
			}
		}
		const branch = (await quiet(["branch", "--show-current"])).trim() || "main";
		log(`Pushing ${branch} to ${slug}…`);
		await git(["push", "-u", "origin", `HEAD:${branch}`]);

		const path = options.path === "/docs" ? "/docs" : "/";
		log("Enabling GitHub Pages…");
		try {
			await this.github(`/repos/${slug}/pages`, {
				method: "POST",
				body: JSON.stringify({ source: { branch, path } }),
			});
		} catch (e) {
			if ((e as any).status !== 409) throw e;
			await this.github(`/repos/${slug}/pages`, {
				method: "PUT",
				body: JSON.stringify({ source: { branch, path } }),
			}).catch(() => {});
		}
		const pages = await this.github(`/repos/${slug}/pages`);
		const url = pages.html_url as string;
		const sha = (await quiet(["rev-parse", "HEAD"])).trim();
		log(`Waiting for CI on ${sha.slice(0, 7)}…`);
		await this.watchActions(slug, sha, log);
		log(`Live at ${url}`);
		return { url, repo: `https://github.com/${slug}` };
	}

	private async deploySsh(dir: string, options: Record<string, any>, log: Log) {
		const h = this.host(options.hostId);
		const remoteDir = (options.remotePath || h.path || "").trim();
		if (!remoteDir) throw new Error("Choose a remote folder to deploy into");
		const config = join(this.home, ".ssh", "config");
		const target = `${h.name}:${remoteDir.replace(/\/?$/, "/")}`;
		log(`Syncing to ${h.user}@${h.host}:${remoteDir}…`);
		await run("ssh", ["-F", config, "-o", "BatchMode=yes", h.name, `mkdir -p '${remoteDir.replace(/'/g, "'\\''")}'`], {
			cwd: dir,
			log,
		});
		const exclude = ["--exclude=.git", "--exclude=node_modules"];
		try {
			await run("rsync", ["-az", "--stats", ...exclude, "-e", `ssh -F ${config} -o BatchMode=yes`, `${dir}/`, target], {
				cwd: dir,
				log,
			});
		} catch (e) {
			if (!/rsync.*(not found|No such file)|protocol/i.test(String((e as Error).message))) throw e;
			log("rsync unavailable on the server, falling back to scp");
			await run("scp", ["-F", config, "-S", "ssh", "-o", "BatchMode=yes", "-r", `${dir}/.`, target], { cwd: dir, log });
		}
		log("Done");
		return { url: null };
	}
}

// ---------------------------------------------------------------------------
// Helpers

/** Runs a command, streaming lines to `log`. Resolves with stdout. */
export function run(cmd: string, args: string[], opts: { cwd: string; log?: Log }): Promise<string> {
	return new Promise((resolve, reject) => {
		const child = spawn(cmd, args, { cwd: opts.cwd, env: process.env });
		let stdout = "";
		const tail: string[] = [];
		const feed = (chunk: Buffer, keep: boolean) => {
			const text = chunk.toString("utf8");
			if (keep) stdout += text;
			// git progress redraws with \r; treat each redraw as a line.
			for (const line of text.split(/\r?\n|\r/)) {
				if (!line.trim()) continue;
				tail.push(line);
				if (tail.length > 20) tail.shift();
				opts.log?.(line);
			}
		};
		child.stdout.on("data", (c) => feed(c, true));
		child.stderr.on("data", (c) => feed(c, false));
		child.on("error", reject);
		child.on("close", (code) => {
			if (code === 0) resolve(stdout);
			else reject(new Error(`${cmd} exited with ${code}\n${tail.slice(-6).join("\n")}`));
		});
	});
}

const SKIP_DIRS = new Set([".git", "node_modules", ".vercel", ".next", ".DS_Store"]);

function walk(root: string, dir = root, out: string[] = []): string[] {
	for (const name of readdirSync(dir)) {
		if (SKIP_DIRS.has(name)) continue;
		const path = join(dir, name);
		const st = statSync(path);
		if (st.isDirectory()) walk(root, path, out);
		else if (st.isFile()) out.push(relative(root, path));
		if (out.length > 5000) throw new Error("Too many files to deploy (over 5000)");
	}
	return out;
}

function parseGithubSlug(url: string): string | null {
	const m = url.match(/github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?\/?$/);
	return m ? m[1] : null;
}

function sanitizeAlias(s: string) {
	return s.trim().replace(/[^A-Za-z0-9._-]+/g, "-") || "server";
}

function sanitizeRepo(s: string) {
	return s.trim().replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "site";
}

function sanitizeProject(s: string) {
	return (
		s
			.toLowerCase()
			.replace(/[^a-z0-9-]+/g, "-")
			.replace(/^-+|-+$/g, "")
			.slice(0, 90) || "site"
	);
}
