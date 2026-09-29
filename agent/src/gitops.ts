/** Git for a project folder: status, diffs, commits, branches, sync, PRs. */

import { spawn } from "node:child_process";

function git(cwd: string, args: string[]): Promise<{ code: number; out: string; err: string }> {
	return new Promise((resolve, reject) => {
		const child = spawn("git", args, { cwd, env: process.env });
		let out = "";
		let err = "";
		child.stdout.on("data", (c) => (out += c));
		child.stderr.on("data", (c) => (err += c));
		child.on("error", reject);
		child.on("close", (code) => resolve({ code: code ?? 1, out, err }));
	});
}

async function ok(cwd: string, args: string[]) {
	const r = await git(cwd, args);
	if (r.code !== 0) throw new Error((r.err || r.out).trim().split("\n").slice(-4).join("\n") || `git ${args[0]} failed`);
	return r.out;
}

export interface FileStatus {
	path: string;
	/** Two-letter porcelain code, e.g. "M ", " M", "??", "A ". */
	code: string;
	staged: boolean;
	unstaged: boolean;
	untracked: boolean;
}

export async function status(cwd: string) {
	const inRepo = await git(cwd, ["rev-parse", "--is-inside-work-tree"]);
	if (inRepo.code !== 0) return { repo: false as const };
	const out = await ok(cwd, ["status", "--porcelain=v1", "-b", "-uall"]);
	const lines = out.split("\n").filter(Boolean);
	const head = lines.shift() ?? "";
	// "## main...origin/main [ahead 1, behind 2]"
	const m = head.match(/^## (?:No commits yet on )?([^.\s]+)(?:\.\.\.(\S+))?(?: \[(.+)\])?/);
	const ahead = Number(head.match(/ahead (\d+)/)?.[1] ?? 0);
	const behind = Number(head.match(/behind (\d+)/)?.[1] ?? 0);
	const files: FileStatus[] = lines.map((l) => {
		const code = l.slice(0, 2);
		return {
			path: l.slice(3).replace(/^"|"$/g, ""),
			code,
			staged: code[0] !== " " && code[0] !== "?",
			unstaged: code[1] !== " ",
			untracked: code === "??",
		};
	});
	const remote = (await git(cwd, ["remote", "get-url", "origin"])).out.trim() || null;
	return { repo: true as const, branch: m?.[1] ?? "HEAD", upstream: m?.[2] ?? null, ahead, behind, remote, files };
}

export async function diff(cwd: string, file?: string, staged = false) {
	const args = ["diff", "--no-color", "-U3"];
	if (staged) args.push("--cached");
	if (file) args.push("--", file);
	let patch = await ok(cwd, args);
	// Untracked files have no diff; show them as all-new.
	if (!patch && file && !staged) {
		const r = await git(cwd, ["diff", "--no-color", "--no-index", "/dev/null", file]);
		patch = r.out;
	}
	return { patch };
}

export async function stage(cwd: string, paths: string[] | "all") {
	await ok(cwd, paths === "all" ? ["add", "-A"] : ["add", "--", ...paths]);
}

export async function unstage(cwd: string, paths: string[] | "all") {
	await ok(cwd, paths === "all" ? ["reset", "-q"] : ["reset", "-q", "--", ...paths]);
}

export async function discard(cwd: string, paths: string[]) {
	for (const p of paths) {
		const tracked = (await git(cwd, ["ls-files", "--error-unmatch", "--", p])).code === 0;
		if (tracked) await ok(cwd, ["checkout", "--", p]);
		else await ok(cwd, ["clean", "-fdq", "--", p]);
	}
}

export async function commit(cwd: string, message: string, all: boolean) {
	if (all) await ok(cwd, ["add", "-A"]);
	await ok(cwd, ["commit", "-q", "-m", message]);
	return (await ok(cwd, ["log", "-1", "--format=%h %s"])).trim();
}

export async function log(cwd: string, limit = 40) {
	const out = await ok(cwd, ["log", `-n${limit}`, "--format=%h%x09%an%x09%ct%x09%s"]).catch(() => "");
	return out
		.split("\n")
		.filter(Boolean)
		.map((l) => {
			const [hash, author, time, subject] = l.split("\t");
			return { hash, author, time: Number(time) * 1000, subject };
		});
}

export async function branches(cwd: string) {
	const out = await ok(cwd, ["branch", "-a", "--format=%(refname:short)%09%(HEAD)"]);
	return out
		.split("\n")
		.filter(Boolean)
		.map((l) => {
			const [name, head] = l.split("\t");
			return { name, current: head === "*", remote: name.startsWith("origin/") };
		})
		.filter((b) => b.name !== "origin/HEAD" && b.name !== "origin");
}

export async function checkout(cwd: string, branch: string, create: boolean) {
	const local = branch.replace(/^origin\//, "");
	if (create) await ok(cwd, ["checkout", "-q", "-b", local]);
	else await ok(cwd, ["checkout", "-q", local]);
}

export async function pull(cwd: string, log: (l: string) => void) {
	const r = await git(cwd, ["pull", "--ff-only"]);
	log((r.out + r.err).trim());
	if (r.code !== 0) throw new Error((r.err || r.out).trim().split("\n").slice(-3).join("\n"));
}

export async function push(cwd: string, log: (l: string) => void) {
	const branch = (await ok(cwd, ["branch", "--show-current"])).trim();
	const r = await git(cwd, ["push", "-u", "origin", `HEAD:${branch}`]);
	log((r.out + r.err).trim());
	if (r.code !== 0) throw new Error((r.err || r.out).trim().split("\n").slice(-3).join("\n"));
}

export function githubSlug(remote: string | null) {
	return remote?.match(/github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?\/?$/)?.[1] ?? null;
}
