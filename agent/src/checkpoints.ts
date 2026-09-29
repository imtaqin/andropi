/**
 * Checkpoints: snapshots of a project folder in a shadow git repository kept
 * in app storage (never inside the project), so any folder can be undone,
 * git repo or not.
 */

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const EXCLUDES = ["node_modules/", ".git/", ".venv/", "venv/", "__pycache__/", ".gradle/", "build/", ".next/", "target/", "*.log"];

function git(args: string[], env: Record<string, string>, cwd: string): Promise<{ code: number; out: string; err: string }> {
	return new Promise((resolve, reject) => {
		const child = spawn("git", args, { cwd, env: { ...process.env, ...env } });
		let out = "";
		let err = "";
		child.stdout.on("data", (c) => (out += c));
		child.stderr.on("data", (c) => (err += c));
		child.on("error", reject);
		child.on("close", (code) => resolve({ code: code ?? 1, out, err }));
	});
}

export interface Checkpoint {
	id: string;
	label: string;
	time: number;
	files: number;
}

export class Checkpoints {
	constructor(private readonly root: string) {}

	private repo(cwd: string) {
		const dir = join(this.root, createHash("sha1").update(cwd).digest("hex").slice(0, 16));
		return { dir, env: { GIT_DIR: dir, GIT_WORK_TREE: cwd, GIT_AUTHOR_NAME: "AndroPI", GIT_AUTHOR_EMAIL: "andropi@local", GIT_COMMITTER_NAME: "AndroPI", GIT_COMMITTER_EMAIL: "andropi@local" } };
	}

	private async ensure(cwd: string) {
		const { dir, env } = this.repo(cwd);
		if (!existsSync(join(dir, "HEAD"))) {
			mkdirSync(dir, { recursive: true });
			await git(["init", "-q"], env, cwd);
			mkdirSync(join(dir, "info"), { recursive: true });
			writeFileSync(join(dir, "info", "exclude"), EXCLUDES.join("\n") + "\n");
		}
		return env;
	}

	/** Records the folder as it is now. Skips when nothing changed since the last one. */
	async snapshot(cwd: string, label: string): Promise<Checkpoint | null> {
		if (!existsSync(cwd)) return null;
		const env = await this.ensure(cwd);
		await git(["add", "-A"], env, cwd);
		const head = await git(["rev-parse", "--verify", "-q", "HEAD"], env, cwd);
		if (head.code === 0) {
			const same = await git(["diff", "--cached", "--quiet", "HEAD"], env, cwd);
			if (same.code === 0) return null;
		}
		const r = await git(["commit", "-q", "--allow-empty", "--no-verify", "-m", label], env, cwd);
		if (r.code !== 0) throw new Error(r.err.trim() || "snapshot failed");
		return (await this.list(cwd, 1))[0] ?? null;
	}

	async list(cwd: string, limit = 50): Promise<Checkpoint[]> {
		const { dir, env } = this.repo(cwd);
		if (!existsSync(join(dir, "HEAD"))) return [];
		const r = await git(["log", `-n${limit}`, "--format=%H%x09%ct%x09%s", "--shortstat"], env, cwd);
		if (r.code !== 0) return [];
		const out: Checkpoint[] = [];
		for (const line of r.out.split("\n")) {
			const parts = line.split("\t");
			if (parts.length === 3) out.push({ id: parts[0], time: Number(parts[1]) * 1000, label: parts[2], files: 0 });
			else if (out.length && /files? changed/.test(line)) out[out.length - 1].files = Number(line.trim().split(" ")[0]) || 0;
		}
		return out;
	}

	/** Files changed since a checkpoint (default: the latest), with a unified diff. */
	async diff(cwd: string, since?: string, file?: string) {
		const env = await this.ensure(cwd);
		const base = since ?? (await git(["rev-parse", "--verify", "-q", "HEAD"], env, cwd)).out.trim();
		if (!base) return { base: null, files: [], patch: "" };
		await git(["add", "-A"], env, cwd);
		const stat = await git(["diff", "--cached", "--numstat", base], env, cwd);
		const files = stat.out
			.split("\n")
			.filter(Boolean)
			.map((l) => {
				const [add, del, path] = l.split("\t");
				return { path, additions: Number(add) || 0, deletions: Number(del) || 0, binary: add === "-" };
			});
		const patch = await git(["diff", "--cached", "--no-color", "-U3", base, ...(file ? ["--", file] : [])], env, cwd);
		return { base, files, patch: patch.out };
	}

	/**
	 * Puts the folder back as it was at a checkpoint. The current state is
	 * saved first, so a restore can itself be undone.
	 */
	async restore(cwd: string, id: string) {
		const env = await this.ensure(cwd);
		await this.snapshot(cwd, "Before restoring a checkpoint");
		await git(["add", "-A"], env, cwd);
		// Files that did not exist at the checkpoint are removed.
		const added = await git(["diff", "--cached", "--name-only", "--diff-filter=A", id], env, cwd);
		for (const f of added.out.split("\n").filter(Boolean)) rmSync(join(cwd, f), { force: true });
		const r = await git(["checkout", "-f", id, "--", "."], env, cwd);
		if (r.code !== 0) throw new Error(r.err.trim() || "restore failed");
		await git(["add", "-A"], env, cwd);
		return { restored: id };
	}
}
