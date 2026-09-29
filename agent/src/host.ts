/**
 * AndroPI agent host.
 *
 * Runs inside the bundled Node runtime on the device and exposes the pi SDK to
 * the Flutter app over JSONL on stdin/stdout:
 *
 *   app  -> host   {"id": 1, "type": "prompt", "text": "..."}
 *   host -> app    {"type": "response", "id": 1, "ok": true, "data": ...}
 *   host -> app    {"type": "event", "event": <pi session event>}
 *   host -> app    {"type": "auth_prompt" | "approval" | "task" | "runs" | ...}
 *
 * stdout is reserved for protocol records; logs go to stderr.
 */

import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
	type AgentSession,
	type AgentSessionEvent,
	createAgentSession,
	DefaultResourceLoader,
	getAgentDir,
	ModelRuntime,
	SessionManager,
	SettingsManager,
	VERSION,
} from "@earendil-works/pi-coding-agent";
import { Checkpoints } from "./checkpoints.js";
import { Container, type Distro } from "./container.js";
import { installDohLookup } from "./dns.js";
import * as gitops from "./gitops.js";
import { Guard } from "./guard.js";
import { Integrations, type Log } from "./integrations.js";
import { installLenientTools } from "./lenient.js";
import { Mcp } from "./mcp.js";
import { type RunSession, Runner } from "./runs.js";
import { Skills } from "./skills.js";
import { webTools } from "./web.js";
import {
	collectFiles,
	dbQuery,
	dbTables,
	detectTests,
	readZip,
	search,
	Templates,
	Tunnels,
	usageSummary,
	writeZip,
} from "./workbench.js";

type Command = { id?: number; type: string; [key: string]: any };

/** Built-in and app tools; MCP tools are added per session. This is the *active* set. */
const TOOLS = ["read", "bash", "edit", "write", "grep", "find", "ls", "web_search", "web_fetch"];

const agentDir = getAgentDir();
const workspace = process.env.ANDROPI_WORKSPACE ?? process.cwd();
const stateDir = join(agentDir, "andropi");

let modelRuntime: ModelRuntime;
let settingsManager: SettingsManager;
let session: AgentSession | undefined;
let integrations: Integrations;
let container: Container;
let skills: Skills;
let templates: Templates;
let checkpoints: Checkpoints;
let runner: Runner;
let mcp: Mcp;
const tunnels = new Tunnels();
let unsubscribe: (() => void) | undefined;

const guard = new Guard({
	send: (r) => send(r),
	checkpoint: async (cwd, label) => {
		await checkpoints.snapshot(cwd, label);
	},
	cwd: () => session?.sessionManager.getCwd() ?? workspace,
});

// ---------------------------------------------------------------------------
// Output

function send(record: object) {
	process.stdout.write(`${JSON.stringify(record)}\n`);
}

function log(...args: unknown[]) {
	process.stderr.write(`${args.map(String).join(" ")}\n`);
}

/** Drop cumulative snapshots from streaming updates, like pi's JSON mode. */
function wireEvent(event: AgentSessionEvent): object {
	if (event.type === "message_update") {
		const { message: _message, assistantMessageEvent, ...rest } = event as any;
		const { partial, ...delta } = assistantMessageEvent ?? {};
		// Tool-call deltas don't name their tool; lift id and name from the snapshot.
		const block = delta.type?.startsWith("toolcall_") ? partial?.content?.[delta.contentIndex] : undefined;
		if (block?.type === "toolCall") Object.assign(delta, { id: block.id, toolName: block.name });
		return { ...rest, assistantMessageEvent: delta };
	}
	return event;
}

// ---------------------------------------------------------------------------
// Sessions

function modelInfo(model: any) {
	if (!model || model.provider === "unknown") return null;
	return {
		provider: model.provider,
		id: model.id,
		name: model.name ?? model.id,
		reasoning: !!model.reasoning,
		contextWindow: model.contextWindow ?? null,
		input: model.input ?? ["text"],
	};
}

function state() {
	const s = session!;
	return {
		model: modelInfo(s.model),
		thinkingLevel: s.thinkingLevel,
		thinkingLevels: s.getAvailableThinkingLevels(),
		isStreaming: s.isStreaming,
		sessionId: s.sessionId,
		sessionFile: s.sessionFile ?? null,
		sessionName: s.sessionName ?? null,
		cwd: s.sessionManager.getCwd(),
		billingNotice: billingNotice(),
		planMode: guard.planMode,
		approvalMode: guard.mode,
	};
}

/** Every session (chat or background run) is built the same way. */
async function buildSession(sessionManager: SessionManager, opts: { interactive: boolean }) {
	const cwd = sessionManager.getCwd();
	const resourceLoader = new DefaultResourceLoader({
		cwd,
		agentDir,
		settingsManager,
		// Approvals and plan mode only make sense with someone watching.
		extensionFactories: opts.interactive ? [{ name: "andropi", factory: guard.extension, hidden: true }] : [],
	});
	await resourceLoader.reload();
	const mcpTools = mcp.toolDefinitions();
	const result = await createAgentSession({
		cwd,
		agentDir,
		modelRuntime,
		settingsManager,
		sessionManager,
		resourceLoader,
		tools: [...TOOLS, ...mcpTools.map((t) => t.name)],
		customTools: [...webTools(() => integrations.searchKeys()), ...mcpTools] as any,
	});
	// Some models send "None" or numbers-as-strings for tool arguments.
	installLenientTools(result.session.agent);
	return result;
}

let lastUserText = "";
let fallbackTried = false;

async function openSession(sessionManager: SessionManager) {
	unsubscribe?.();
	guard.cancelAll();
	session?.dispose();
	const result = await buildSession(sessionManager, { interactive: true });
	session = result.session;
	unsubscribe = session.subscribe((event) => {
		send({ type: "event", event: wireEvent(event) });
		onSessionEvent(event);
	});
	if (result.modelFallbackMessage) send({ type: "notice", message: result.modelFallbackMessage });
	return state();
}

/** Hooks on the active chat: model fallback and "done" notifications. */
function onSessionEvent(event: AgentSessionEvent) {
	if (event.type === "message_end") {
		const m = (event as any).message;
		if (m?.role === "assistant" && m.stopReason === "error") void tryFallback(String(m.errorMessage ?? ""));
	}
	if (event.type === "agent_end" || (event as any).type === "agent_settled") {
		const text = session?.getLastAssistantText?.() ?? "";
		send({ type: "agent_done", sessionFile: session?.sessionFile ?? null, preview: text.slice(0, 200) });
	}
}

async function tryFallback(error: string) {
	const chain = integrations.settings.fallbackModels ?? [];
	if (!chain.length || fallbackTried || !session) return;
	if (!/rate|limit|quota|overload|429|5\d\d|unavailable|insufficient|credit|exceeded|timeout/i.test(error)) return;
	const current = `${session.model?.provider}/${session.model?.id}`;
	const next = chain.find((f) => `${f.provider}/${f.model}` !== current);
	const model = next && modelRuntime.getModel(next.provider, next.model);
	if (!model) return;
	fallbackTried = true;
	await session.setModel(model, { persist: false });
	send({ type: "notice", message: `Switched to ${model.name ?? model.id} after an error: ${error.slice(0, 120)}` });
	send({ type: "state", state: state() });
	session.prompt("Continue where you left off (the previous model failed).").catch(() => {});
}

/** Refuses new work once today's spend reaches the configured cap. */
function checkBudget() {
	const cap = integrations.settings.dailyBudget ?? 0;
	if (!cap) return;
	const today = new Date().toISOString().slice(0, 10);
	const spent = usageSummary(join(agentDir, "sessions"), 1)
		.filter((r) => r.day === today)
		.reduce((sum, r) => sum + r.cost, 0);
	if (spent >= cap) throw new Error(`Daily budget of $${cap.toFixed(2)} reached ($${spent.toFixed(2)} spent). Raise it in Settings → Usage.`);
}

/** Mirrors pi's interactive warning: subscription OAuth outside Claude's own apps bills extra usage. */
function billingNotice(): string | null {
	if (session?.model?.provider !== "anthropic" || !modelRuntime.isUsingOAuth("anthropic")) return null;
	if (settingsManager.getWarnings().anthropicExtraUsage === false) return null;
	return "Claude subscription sign-in bills third-party apps like this one per token from extra usage, not your plan limits. Manage it at claude.ai/settings/usage, or use an API key.";
}

/** Rebuilds the active session so tool settings (shell, MCP tools) take effect. */
async function reopenSession() {
	const s = session!;
	if (s.isStreaming) throw new Error("Wait for the agent to finish first");
	const file = s.sessionFile;
	await openSession(file ? SessionManager.open(file) : SessionManager.create(s.sessionManager.getCwd()));
}

/** A headless session for the background runner. */
async function backgroundSession(cwd: string): Promise<RunSession> {
	const { session: bg } = await buildSession(SessionManager.create(cwd || workspace), { interactive: false });
	let error: string | undefined;
	bg.subscribe((e) => {
		const m = (e as any).message;
		if (e.type === "message_end" && m?.role === "assistant" && m.stopReason === "error") error = m.errorMessage;
	});
	return {
		sessionFile: bg.sessionFile,
		prompt: async (text) => {
			checkBudget();
			await bg.prompt(text);
		},
		lastText: () => bg.getLastAssistantText(),
		errorText: () => error,
		abort: () => bg.abort(),
		dispose: () => bg.dispose(),
	};
}

const AGENTS_MARKER = "<!-- andropi:managed (delete this line to keep your own edits) -->";

/** Keeps the environment notes current, unless the user has taken the file over. */
function ensureAgentsFile() {
	const path = join(agentDir, "AGENTS.md");
	if (existsSync(path)) {
		const current = readFileSync(path, "utf8");
		const ours = current.includes(AGENTS_MARKER) || current.startsWith("# Environment\n\nYou are running inside AndroPI");
		if (!ours) return;
	}
	writeFileSync(
		path,
		`${AGENTS_MARKER}
# Environment

You are running inside AndroPI, an Android app, on the user's phone.

- The shell is Android's /system/bin/sh (mksh) with toybox utilities, not bash.
  Prefer POSIX sh syntax. There is no sudo, apt or pkg.
- On PATH: \`node\`, \`git\`, \`ssh\`, \`ssh-keygen\`, \`scp\`, \`rsync\`, \`curl\`, \`rg\`, \`fd\`.
  With scp, pass \`-S ssh\`.
- The workspace directory is ${workspace}. Projects live in subfolders of it.
  Keep files inside it unless asked otherwise.
- When the user has connected accounts in the app:
  - GitHub: \`$GITHUB_TOKEN\` is set and git is already authenticated for
    https://github.com (clone, pull, push work directly). Use the REST API
    with curl for everything else (issues, PRs, repos).
  - Vercel: \`$VERCEL_TOKEN\` is set for the Vercel REST API.
  - SSH: saved servers are aliases in ~/.ssh/config, so \`ssh <name>\` works.
    The device key is ~/.ssh/id_ed25519.
- Linux container: when the user has installed one (Debian or Alpine, via
  proot), \`box -c '<command>'\` runs a command inside it, and \`box\` alone opens
  a shell. When it is enabled as your shell, every command already runs inside:
  use \`apt-get install -y\` (Debian) or \`apk add\` (Alpine) to get Python,
  Node.js, compilers and anything else. The home folder and workspace are the
  same paths inside and out.
- You have \`web_search\` and \`web_fetch\` tools. Use them before guessing how
  to install or use something, and to look up unfamiliar errors.
- Dev servers: run them in the background (\`nohup npm run dev > dev.log 2>&1 &\`)
  and print the URL (e.g. http://localhost:5173); the app offers a live
  preview and a public link for any localhost port it sees.
- Some actions need the user's approval in the app; if one is declined, ask
  what they want instead rather than retrying.
- There is no display server; do not try to open GUIs or browsers. The app can
  preview HTML files you write.
`,
	);
}

// ---------------------------------------------------------------------------
// Login bridge: pi's AuthInteraction is forwarded to the app.

let nextAuthId = 1;
const pendingAuth = new Map<number, { resolve: (v: string) => void; reject: (e: Error) => void }>();

async function login(providerId: string, method: "api_key" | "oauth") {
	const controller = new AbortController();
	await modelRuntime.login(providerId, method, {
		signal: controller.signal,
		prompt: (prompt) =>
			new Promise<string>((resolve, reject) => {
				const authId = nextAuthId++;
				pendingAuth.set(authId, { resolve, reject });
				const { signal, ...rest } = prompt;
				signal?.addEventListener("abort", () => {
					pendingAuth.delete(authId);
					send({ type: "auth_dismiss", authId });
					reject(new Error("cancelled"));
				});
				send({ type: "auth_prompt", authId, provider: providerId, prompt: rest });
			}),
		notify: (event) => send({ type: "auth_event", provider: providerId, event }),
	});
}

async function providers() {
	const out = [];
	for (const p of modelRuntime.getProviders()) {
		const auth = p.auth as any;
		out.push({
			id: p.id,
			name: p.name,
			configured: modelRuntime.hasConfiguredAuth(p.id),
			oauth: modelRuntime.isUsingOAuth(p.id),
			methods: [auth.apiKey?.login ? "api_key" : null, auth.oauth ? "oauth" : null].filter(Boolean),
			models: modelRuntime.getModels(p.id).length,
		});
	}
	return out;
}

// ---------------------------------------------------------------------------
// Backups

function backupTarget() {
	const stamp = new Date().toISOString().slice(0, 16).replace(/[-:T]/g, "");
	const shared = "/storage/emulated/0/Download";
	const dir = existsSync(shared) ? join(shared, "AndroPI") : join(workspace, "backups");
	try {
		mkdirSync(dir, { recursive: true });
		writeFileSync(join(dir, ".probe"), "");
		unlinkSync(join(dir, ".probe"));
		return join(dir, `andropi-backup-${stamp}.zip`);
	} catch {
		mkdirSync(join(workspace, "backups"), { recursive: true });
		return join(workspace, "backups", `andropi-backup-${stamp}.zip`);
	}
}

function createBackup(includeWorkspace: boolean) {
	// Secrets (provider keys, tokens) are left out on purpose.
	const entries = [
		...collectFiles(join(agentDir, "sessions"), agentDir),
		...collectFiles(join(agentDir, "skills"), agentDir),
		...collectFiles(join(agentDir, "prompts"), agentDir),
		...["settings.json", "AGENTS.md", "andropi/runs.json"]
			.filter((f) => existsSync(join(agentDir, f)))
			.map((f) => ({ name: f, data: readFileSync(join(agentDir, f)) })),
	].map((e) => ({ name: `agent/${e.name}`, data: e.data }));
	if (includeWorkspace) {
		for (const e of collectFiles(workspace, workspace, new Set(["node_modules", ".git", "backups", ".venv", "venv"]))) {
			entries.push({ name: `workspace/${e.name}`, data: e.data });
		}
	}
	const path = backupTarget();
	writeFileSync(path, writeZip(entries));
	return { path, files: entries.length };
}

function restoreBackup(path: string) {
	const entries = readZip(readFileSync(path));
	let restored = 0;
	for (const e of entries) {
		const [root, ...rest] = e.name.split("/");
		const rel = rest.join("/");
		if (!rel || rel.split("/").includes("..")) continue;
		const base = root === "agent" ? agentDir : root === "workspace" ? workspace : null;
		if (!base) continue;
		const target = join(base, rel);
		mkdirSync(dirname(target), { recursive: true });
		writeFileSync(target, e.data);
		restored++;
	}
	return { restored };
}

// ---------------------------------------------------------------------------
// Commands

async function handle(cmd: Command): Promise<unknown> {
	const s = session!;
	const cwd = (cmd.dir as string | undefined) ?? s.sessionManager.getCwd();
	switch (cmd.type) {
		case "hello":
			return { version: VERSION, node: process.version, agentDir, workspace, tools: s.getActiveToolNames(), ...state() };
		case "state":
			return state();

		case "prompt": {
			checkBudget();
			lastUserText = cmd.text;
			fallbackTried = false;
			// Plan mode: ask for a plan first; tools that change things are blocked (guard.ts).
			const text = guard.planMode
				? `${cmd.text}\n\n[Plan mode] Investigate as needed, then reply with a numbered plan only. Do not change files or run commands that modify anything until I approve.`
				: cmd.text;
			// Don't await the run; progress arrives as events.
			s.prompt(text, {
				images: cmd.images,
				streamingBehavior: s.isStreaming ? (cmd.behavior ?? "followUp") : undefined,
			}).catch((e) => send({ type: "error", message: String(e?.message ?? e) }));
			return null;
		}
		case "steer":
			await s.steer(cmd.text);
			return null;
		case "abort":
			guard.cancelAll();
			await s.abort();
			return null;
		case "session_stats":
			return { ...s.getSessionStats(), context: s.getContextUsage() ?? null };

		// Approvals and plan mode (guard.ts).
		case "approval_reply":
			guard.reply(cmd.approvalId, !!cmd.allow, !!cmd.always, cmd.key);
			return null;
		case "plan_mode":
			guard.planMode = !!cmd.on;
			return state();
		case "plan_approve":
			guard.planMode = false;
			s.prompt(cmd.text || "The plan is approved. Carry it out now, step by step.").catch((e) =>
				send({ type: "error", message: String(e?.message ?? e) }),
			);
			return state();

		// Editing and forking the conversation.
		case "fork_points":
			return s.getUserMessagesForForking();
		case "edit_message": {
			// Moves back to just before that message; the text returns for editing.
			const r = await s.navigateTree(cmd.entryId, {});
			return { text: r.editorText ?? "", cancelled: r.cancelled };
		}
		case "fork_session": {
			const source = s.sessionFile;
			if (!source) throw new Error("Nothing to fork yet");
			await openSession(SessionManager.forkFrom(source, s.sessionManager.getCwd()));
			const r = cmd.entryId ? await session!.navigateTree(cmd.entryId, {}) : { editorText: "" };
			return { ...state(), text: r.editorText ?? "" };
		}

		case "providers":
			return providers();
		case "models":
			return (await modelRuntime.getAvailable(cmd.provider)).map(modelInfo);
		case "set_model": {
			const model = modelRuntime.getModel(cmd.provider, cmd.model);
			if (!model) throw new Error(`Unknown model ${cmd.provider}/${cmd.model}`);
			await s.setModel(model, { persist: true });
			return state();
		}
		case "set_thinking":
			s.setThinkingLevel(cmd.level, { persist: true });
			return state();

		case "login":
			await login(cmd.provider, cmd.method ?? "api_key");
			return providers();
		case "auth_reply": {
			const pending = pendingAuth.get(cmd.authId);
			pendingAuth.delete(cmd.authId);
			if (cmd.cancel) pending?.reject(new Error("cancelled"));
			else pending?.resolve(String(cmd.value ?? ""));
			return null;
		}
		case "logout":
			await modelRuntime.logout(cmd.provider);
			return providers();

		case "new_session":
			return openSession(SessionManager.create(cmd.cwd ?? workspace));
		case "sessions":
			return (await SessionManager.listAll()).map((info) => ({
				path: info.path,
				id: info.id,
				cwd: info.cwd,
				name: info.name ?? null,
				modified: info.modified.getTime(),
				messageCount: info.messageCount,
				firstMessage: info.firstMessage,
			}));
		case "open_session":
			return openSession(SessionManager.open(cmd.path));
		case "rename_session": {
			const name = String(cmd.name ?? "").trim();
			if (!name) throw new Error("Name is empty");
			if (cmd.path === s.sessionFile) s.setSessionName(name);
			else SessionManager.open(cmd.path).appendSessionInfo(name);
			return null;
		}
		case "delete_session":
			if (cmd.path === s.sessionFile) throw new Error("Switch to another session before deleting this one");
			unlinkSync(cmd.path);
			return null;
		case "messages":
			return s.messages;

		// Accounts, repositories, SSH and deploys (integrations.ts).
		case "integrations":
			return integrations.summary();
		case "github_login":
			return integrations.githubLogin(cmd.token);
		case "github_device_start":
			return integrations.githubDeviceStart();
		case "github_device_poll":
			return integrations.githubDevicePoll(cmd.deviceCode);
		case "github_logout":
			return integrations.githubLogout();
		case "github_repos":
			return integrations.repos();
		case "git_clone":
			return integrations.clone(cmd.repo, taskLog(cmd));
		case "projects":
			return integrations.projects();
		case "ssh_key":
			return integrations.sshKey();
		case "ssh_host_save":
			return integrations.saveSshHost(cmd.host);
		case "ssh_host_delete":
			return integrations.deleteSshHost(cmd.hostId);
		case "ssh_test":
			return integrations.sshTest(cmd.hostId, taskLog(cmd));
		case "vercel_login":
			return integrations.vercelLogin(cmd.token);
		case "vercel_logout":
			return integrations.vercelLogout();
		case "ci_watch":
			return integrations.watchProject(cwd, taskLog(cmd));
		case "deploy":
			return integrations.deploy(cmd.target, cwd, cmd.options ?? {}, taskLog(cmd));

		// Git for the project folder (gitops.ts).
		case "git_status":
			return gitops.status(cwd);
		case "git_diff":
			return gitops.diff(cwd, cmd.file, !!cmd.staged);
		case "git_stage":
			await gitops.stage(cwd, cmd.paths ?? "all");
			return gitops.status(cwd);
		case "git_unstage":
			await gitops.unstage(cwd, cmd.paths ?? "all");
			return gitops.status(cwd);
		case "git_discard":
			await gitops.discard(cwd, cmd.paths ?? []);
			return gitops.status(cwd);
		case "git_commit":
			return { commit: await gitops.commit(cwd, String(cmd.message ?? "").trim() || "Update", !!cmd.all) };
		case "git_log":
			return gitops.log(cwd, cmd.limit ?? 40);
		case "git_branches":
			return gitops.branches(cwd);
		case "git_checkout":
			await gitops.checkout(cwd, cmd.branch, !!cmd.create);
			return gitops.status(cwd);
		case "git_pull":
			await gitops.pull(cwd, taskLog(cmd));
			return gitops.status(cwd);
		case "git_push":
			await gitops.push(cwd, taskLog(cmd));
			return gitops.status(cwd);
		case "github_pr_create": {
			const st = await gitops.status(cwd);
			const slug = st.repo ? gitops.githubSlug(st.remote) : null;
			if (!st.repo || !slug) throw new Error("This folder has no GitHub remote");
			if (st.ahead > 0 || !st.upstream) await gitops.push(cwd, () => {});
			const repo = await integrations.githubApi(`/repos/${slug}`);
			const pr = await integrations.githubApi(`/repos/${slug}/pulls`, {
				method: "POST",
				body: JSON.stringify({ title: cmd.title, body: cmd.body ?? "", head: st.branch, base: cmd.base || repo.default_branch }),
			});
			return { url: pr.html_url, number: pr.number };
		}
		case "github_issues": {
			const st = await gitops.status(cwd);
			const slug = cmd.repo ?? (st.repo ? gitops.githubSlug(st.remote) : null);
			if (!slug) throw new Error("This folder has no GitHub remote");
			const list = await integrations.githubApi(`/repos/${slug}/issues?state=${cmd.state ?? "open"}&per_page=50`);
			return {
				repo: slug,
				issues: (list as any[]).map((i) => ({
					number: i.number,
					title: i.title,
					body: i.body ?? "",
					url: i.html_url,
					author: i.user?.login,
					labels: (i.labels ?? []).map((l: any) => l.name),
					comments: i.comments,
					isPr: !!i.pull_request,
					updatedAt: Date.parse(i.updated_at),
				})),
			};
		}

		// Checkpoints (checkpoints.ts).
		case "checkpoints":
			return checkpoints.list(cwd);
		case "checkpoint_create":
			return checkpoints.snapshot(cwd, cmd.label || "Manual checkpoint");
		case "checkpoint_diff":
			return checkpoints.diff(cwd, cmd.checkpoint, cmd.file);
		case "checkpoint_restore":
			if (s.isStreaming) throw new Error("Stop the agent before restoring");
			return checkpoints.restore(cwd, cmd.checkpoint);

		// Project tools (workbench.ts).
		case "search":
			return search(cwd, String(cmd.query ?? ""), { regex: !!cmd.regex, caseSensitive: !!cmd.caseSensitive, glob: cmd.glob });
		case "db_tables":
			return dbTables(cmd.path);
		case "db_query":
			return dbQuery(cmd.path, String(cmd.sql ?? ""), cmd.limit ?? 200);
		case "tests_detect":
			return detectTests(cwd);
		case "tunnel_start":
			return {
				url: await tunnels.start(Number(cmd.port), (u) => send({ type: "tunnel", ...u })),
			};
		case "tunnel_stop":
			tunnels.stop(Number(cmd.port));
			return tunnels.list();
		case "tunnels":
			return tunnels.list();
		case "usage":
			return usageSummary(join(agentDir, "sessions"), cmd.days ?? 30);

		// Prompt templates: slash commands pi expands.
		case "templates":
			return templates.list();
		case "template_save": {
			const name = templates.save(cmd.name, cmd.description ?? "", cmd.body ?? "", cmd.argumentHint);
			await s.reload();
			return { name, templates: templates.list() };
		}
		case "template_delete":
			templates.remove(cmd.name);
			await s.reload();
			return templates.list();
		case "slash_commands":
			return {
				templates: templates.list().map((t) => ({ name: t.name, description: t.description, hint: t.argumentHint })),
				skills: skills.list().map((k) => ({ name: `skill:${k.name}`, description: k.description, hint: null })),
			};

		// Background runs, queue and schedules (runs.ts).
		case "runs":
			return runner.summary();
		case "run_enqueue":
			checkBudget();
			return runner.enqueue(String(cmd.prompt ?? ""), cwd, cmd.title);
		case "run_cancel":
			await runner.cancel(cmd.runId);
			return runner.summary();
		case "runs_clear":
			runner.clearFinished();
			return runner.summary();
		case "runs_concurrency":
			runner.setConcurrency(cmd.n);
			return runner.summary();
		case "schedule_save":
			runner.saveSchedule({ ...cmd.schedule, cwd: cmd.schedule?.cwd || cwd });
			return runner.summary();
		case "schedule_delete":
			runner.deleteSchedule(cmd.scheduleId);
			return runner.summary();
		case "schedule_run":
			runner.runScheduleNow(cmd.scheduleId);
			return runner.summary();

		// MCP servers (mcp.ts). Tools refresh on the next session rebuild.
		case "mcp_servers":
			return mcp.summary();
		case "mcp_save": {
			const out = await mcp.upsert(cmd.server ?? {});
			if (!s.isStreaming) await reopenSession();
			return out;
		}
		case "mcp_delete": {
			const out = await mcp.remove(cmd.serverId);
			if (!s.isStreaming) await reopenSession();
			return out;
		}

		// Backups.
		case "backup_create":
			return createBackup(!!cmd.includeWorkspace);
		case "backup_restore":
			return restoreBackup(cmd.path);

		// Linux container (container.ts).
		case "container_status":
			return container.status(settingsManager.getShellPath());
		case "container_install": {
			await container.install(cmd.distro as Distro, taskLog(cmd), integrations.settings.dns);
			// On by default once installed, unless the user turned it off before.
			if (integrations.settings.containerShell !== false) {
				settingsManager.setShellPath(container.shellPath);
				await settingsManager.flush();
				await reopenSession().catch(() => {});
			}
			return container.status(settingsManager.getShellPath());
		}
		case "container_remove":
			if (settingsManager.getShellPath() === container.shellPath) settingsManager.setShellPath(undefined);
			container.remove();
			await reopenSession();
			return container.status(settingsManager.getShellPath());
		case "container_enable":
			if (cmd.on && !container.status(undefined).installed) throw new Error("Install the container first");
			settingsManager.setShellPath(cmd.on ? container.shellPath : undefined);
			integrations.updateSettings({ containerShell: !!cmd.on });
			await settingsManager.flush();
			await reopenSession();
			return container.status(settingsManager.getShellPath());

		// App settings: DNS, search keys, approvals, fallbacks, budget.
		case "settings_get":
			return integrations.publicSettings();
		case "settings_set": {
			const out = integrations.updateSettings(cmd.settings ?? {});
			container.setNameservers(integrations.settings.dns);
			guard.mode = integrations.settings.approvalMode ?? "ask_risky";
			return out;
		}

		// Agent skills (skills.ts). pi rescans them on reload.
		case "skills_list":
			return skills.list();
		case "skills_search":
			return skills.search(cmd.query ?? "");
		case "skills_browse":
			return skills.browse(cmd.spec);
		case "skills_install": {
			const added = await skills.install(cmd.spec, taskLog(cmd));
			await s.reload();
			return added;
		}
		case "skills_remove":
			skills.remove(cmd.path);
			await s.reload();
			return skills.list();

		default:
			throw new Error(`Unknown command: ${cmd.type}`);
	}
}

/** Streams a long command's output to the app as `task` records. */
function taskLog(cmd: Command): Log {
	const taskId = cmd.taskId ?? cmd.id;
	const log: Log = (line: string) => send({ type: "task", taskId, line });
	log.ci = (ci) => send({ type: "task", taskId, ci });
	return log;
}

async function dispatch(line: string) {
	let cmd: Command;
	try {
		cmd = JSON.parse(line);
	} catch (e) {
		send({ type: "response", ok: false, error: `Bad JSON: ${(e as Error).message}` });
		return;
	}
	try {
		const data = await handle(cmd);
		send({ type: "response", id: cmd.id, ok: true, data });
	} catch (e) {
		send({ type: "response", id: cmd.id, ok: false, error: String((e as Error)?.message ?? e) });
	}
}

// ---------------------------------------------------------------------------
// Startup

async function main() {
	mkdirSync(agentDir, { recursive: true });
	mkdirSync(workspace, { recursive: true });
	mkdirSync(stateDir, { recursive: true });
	ensureAgentsFile();

	// Route every lookup through DNS-over-HTTPS (configurable in settings).
	installDohLookup();
	integrations = new Integrations(agentDir, workspace);
	guard.mode = integrations.settings.approvalMode ?? "ask_risky";
	skills = new Skills(agentDir, join(fileURLToPath(new URL(".", import.meta.url)), "skills"), () => process.env.GITHUB_TOKEN);
	skills.seed();
	templates = new Templates(agentDir);
	templates.seed(join(stateDir, "seeded-templates.json"));
	checkpoints = new Checkpoints(join(stateDir, "checkpoints"));
	container = new Container(process.env.ANDROPI_FILES ?? join(agentDir, "..", "..", ".."));
	mcp = new Mcp(join(stateDir, "mcp.json"), () => send({ type: "mcp", servers: mcp.summary() }));
	modelRuntime = await ModelRuntime.create();
	settingsManager = SettingsManager.create(workspace, agentDir);
	// Linux container is the agent's shell by default once installed.
	if (
		container.status(undefined).installed &&
		integrations.settings.containerShell !== false &&
		settingsManager.getShellPath() !== container.shellPath
	) {
		settingsManager.setShellPath(container.shellPath);
		await settingsManager.flush();
	}
	await openSession(SessionManager.continueRecent(workspace));
	runner = new Runner(join(stateDir, "runs.json"), backgroundSession, send, (p) => integrations.githubApi(p));

	// Starter skills and MCP connections come up in the background; the chat
	// session is rebuilt afterwards (when idle) so it sees them.
	void Promise.allSettled([skills.installStarter((line) => log("skills:", line)), mcp.connectAll()]).then(() => {
		if (session && !session.isStreaming) return reopenSession().catch(() => {});
	});

	// Split on LF only; readline would also split on U+2028/U+2029.
	let buffer = "";
	process.stdin.setEncoding("utf8");
	process.stdin.on("data", (chunk: string) => {
		buffer += chunk;
		let nl: number;
		while ((nl = buffer.indexOf("\n")) >= 0) {
			const line = buffer.slice(0, nl).replace(/\r$/, "");
			buffer = buffer.slice(nl + 1);
			if (line.trim()) void dispatch(line);
		}
	});
	process.stdin.on("end", () => {
		tunnels.stopAll();
		runner.dispose();
		void mcp.dispose();
		session?.dispose();
		process.exit(0);
	});

	send({ type: "ready", version: VERSION });
}

main().catch((e) => {
	log("fatal:", e?.stack ?? e);
	send({ type: "fatal", message: String(e?.message ?? e) });
	process.exit(1);
});
