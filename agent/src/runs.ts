/**
 * Background agent runs: a queue (with a concurrency limit, so several agents
 * can work at once), scheduled tasks, and GitHub issue triggers. Each run is
 * its own pi session, so the result can be opened later as a normal chat.
 */

import { existsSync, readFileSync, writeFileSync } from "node:fs";

export interface RunSession {
	sessionFile?: string;
	prompt(text: string): Promise<void>;
	lastText(): string | undefined;
	errorText(): string | undefined;
	abort(): Promise<void>;
	dispose(): void;
}

export interface Run {
	id: string;
	title: string;
	prompt: string;
	cwd: string;
	status: "queued" | "running" | "done" | "error" | "cancelled";
	source: "queue" | "schedule" | "trigger";
	createdAt: number;
	startedAt?: number;
	finishedAt?: number;
	sessionFile?: string;
	summary?: string;
}

export interface Schedule {
	id: string;
	name: string;
	prompt: string;
	cwd: string;
	enabled: boolean;
	/** Run every N minutes, or daily at "HH:MM" (device time). */
	everyMinutes?: number;
	dailyAt?: string;
	/** Optional trigger instead of a clock: new GitHub issues with a label. */
	trigger?: { type: "github_issues"; repo: string; label: string; seen?: number[] };
	lastRun?: number;
}

interface Store {
	runs: Run[];
	schedules: Schedule[];
	concurrency: number;
}

export class Runner {
	private store: Store = { runs: [], schedules: [], concurrency: 1 };
	private active = new Map<string, RunSession>();
	private timer?: NodeJS.Timeout;

	constructor(
		private readonly file: string,
		private readonly makeSession: (cwd: string) => Promise<RunSession>,
		private readonly notify: (record: object) => void,
		private readonly github: (path: string) => Promise<any>,
	) {
		if (existsSync(file)) {
			try {
				this.store = { runs: [], schedules: [], concurrency: 1, ...JSON.parse(readFileSync(file, "utf8")) };
			} catch {}
		}
		// Runs interrupted by an app restart cannot resume.
		for (const r of this.store.runs) if (r.status === "running") r.status = "error";
		this.timer = setInterval(() => void this.tick(), 60_000);
		setTimeout(() => void this.tick(), 5_000);
	}

	private save() {
		this.store.runs = this.store.runs.slice(0, 100);
		writeFileSync(this.file, JSON.stringify(this.store, null, 1));
	}

	summary() {
		return {
			runs: this.store.runs,
			schedules: this.store.schedules,
			concurrency: this.store.concurrency,
			running: this.active.size,
			keepAlive: this.keepAlive(),
		};
	}

	/** Whether the app should stay alive in the background (runs or schedules pending). */
	keepAlive() {
		return this.active.size > 0 || this.store.runs.some((r) => r.status === "queued") || this.store.schedules.some((s) => s.enabled);
	}

	private changed() {
		this.save();
		this.notify({ type: "runs", ...this.summary() });
	}

	setConcurrency(n: number) {
		this.store.concurrency = Math.min(Math.max(Math.round(n) || 1, 1), 3);
		this.changed();
		this.pump();
	}

	enqueue(prompt: string, cwd: string, title?: string, source: Run["source"] = "queue") {
		const run: Run = {
			id: `r${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`,
			title: title || prompt.split("\n")[0].slice(0, 80),
			prompt,
			cwd,
			status: "queued",
			source,
			createdAt: Date.now(),
		};
		this.store.runs.unshift(run);
		this.changed();
		this.pump();
		return run;
	}

	async cancel(id: string) {
		const run = this.store.runs.find((r) => r.id === id);
		if (!run) return;
		if (run.status === "running") await this.active.get(id)?.abort();
		if (run.status === "queued" || run.status === "running") run.status = "cancelled";
		this.changed();
	}

	clearFinished() {
		this.store.runs = this.store.runs.filter((r) => r.status === "queued" || r.status === "running");
		this.changed();
	}

	private pump() {
		while (this.active.size < this.store.concurrency) {
			const next = [...this.store.runs].reverse().find((r) => r.status === "queued");
			if (!next) return;
			void this.start(next);
		}
	}

	private async start(run: Run) {
		run.status = "running";
		run.startedAt = Date.now();
		this.changed();
		let session: RunSession | undefined;
		try {
			session = await this.makeSession(run.cwd);
			this.active.set(run.id, session);
			run.sessionFile = session.sessionFile;
			this.changed();
			await session.prompt(run.prompt);
			const err = session.errorText();
			if ((run.status as string) === "cancelled") return;
			run.status = err ? "error" : "done";
			run.summary = (err ?? session.lastText() ?? "").slice(0, 600);
		} catch (e) {
			if ((run.status as string) !== "cancelled") {
				run.status = "error";
				run.summary = String((e as Error).message ?? e).slice(0, 600);
			}
		} finally {
			run.finishedAt = Date.now();
			this.active.delete(run.id);
			session?.dispose();
			this.changed();
			this.notify({ type: "run_finished", run });
			this.pump();
		}
	}

	// -------------------------------------------------------------------------
	// Schedules

	saveSchedule(s: Partial<Schedule>) {
		if (!s.name?.trim() || !s.prompt?.trim()) throw new Error("A schedule needs a name and a prompt");
		if (!s.trigger && !s.everyMinutes && !s.dailyAt) throw new Error("Choose how often it runs");
		const entry: Schedule = {
			id: s.id ?? `s${Date.now().toString(36)}`,
			name: s.name.trim(),
			prompt: s.prompt.trim(),
			cwd: s.cwd ?? "",
			enabled: s.enabled ?? true,
			everyMinutes: s.everyMinutes ? Math.max(15, Math.round(s.everyMinutes)) : undefined,
			dailyAt: s.dailyAt || undefined,
			trigger: s.trigger,
			lastRun: s.lastRun,
		};
		const i = this.store.schedules.findIndex((x) => x.id === entry.id);
		if (i >= 0) this.store.schedules[i] = { ...this.store.schedules[i], ...entry };
		else this.store.schedules.push(entry);
		this.changed();
		return entry;
	}

	deleteSchedule(id: string) {
		this.store.schedules = this.store.schedules.filter((s) => s.id !== id);
		this.changed();
	}

	runScheduleNow(id: string) {
		const s = this.store.schedules.find((x) => x.id === id);
		if (!s) throw new Error("Unknown schedule");
		s.lastRun = Date.now();
		return this.enqueue(s.prompt, s.cwd, s.name, "schedule");
	}

	private due(s: Schedule, now: Date) {
		if (s.everyMinutes) return !s.lastRun || now.getTime() - s.lastRun >= s.everyMinutes * 60_000;
		if (s.dailyAt) {
			const [h, m] = s.dailyAt.split(":").map(Number);
			const today = new Date(now);
			today.setHours(h, m, 0, 0);
			return now >= today && (!s.lastRun || s.lastRun < today.getTime());
		}
		return false;
	}

	private async tick() {
		const now = new Date();
		for (const s of this.store.schedules) {
			if (!s.enabled) continue;
			if (s.trigger?.type === "github_issues") {
				// Poll at most every 10 minutes.
				if (s.lastRun && now.getTime() - s.lastRun < 10 * 60_000) continue;
				s.lastRun = now.getTime();
				await this.pollIssues(s).catch((e) => this.notify({ type: "notice", message: `Trigger ${s.name}: ${e.message}` }));
				continue;
			}
			if (this.due(s, now)) {
				s.lastRun = now.getTime();
				this.enqueue(s.prompt, s.cwd, s.name, "schedule");
			}
		}
		this.save();
	}

	private async pollIssues(s: Schedule) {
		const t = s.trigger!;
		const issues: any[] = await this.github(
			`/repos/${t.repo}/issues?state=open&labels=${encodeURIComponent(t.label)}&per_page=20&sort=created&direction=desc`,
		);
		const seen = new Set(t.seen ?? []);
		const first = t.seen === undefined;
		for (const issue of issues.filter((i) => !i.pull_request)) {
			if (seen.has(issue.number)) continue;
			seen.add(issue.number);
			// The first poll only records what already exists.
			if (first) continue;
			this.enqueue(
				`${s.prompt}\n\nGitHub issue ${t.repo}#${issue.number}: ${issue.title}\n\n${issue.body ?? ""}\n\n${issue.html_url}`,
				s.cwd,
				`${s.name}: #${issue.number} ${issue.title}`,
				"trigger",
			);
		}
		t.seen = [...seen].slice(-200);
		this.changed();
	}

	dispose() {
		if (this.timer) clearInterval(this.timer);
	}
}
