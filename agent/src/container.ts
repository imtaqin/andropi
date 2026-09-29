/**
 * A Linux userland for the agent: an official Debian or Alpine image pulled
 * from Docker Hub, unpacked into app storage and entered through proot
 * (tool/box.sh, on PATH as `box`). With it enabled, pi's bash tool runs inside,
 * so `apt install nodejs python3` just works.
 */

import { chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join, normalize } from "node:path";
import { createGunzip } from "node:zlib";
import { Readable } from "node:stream";
import { NAMESERVERS, type DnsMode } from "./dns.js";
import { type Log, run } from "./integrations.js";

export type Distro = "debian" | "alpine";

/** The Docker platform matching this phone's CPU (node reports the ABI the APK was installed for). */
const PLATFORM =
	process.arch === "arm"
		? { architecture: "arm", variant: "v7", label: "linux/arm/v7" }
		: process.arch === "x64"
			? { architecture: "amd64", variant: undefined, label: "linux/amd64" }
			: { architecture: "arm64", variant: undefined, label: "linux/arm64" };

const IMAGES: Record<Distro, { repo: string; tag: string; label: string }> = {
	debian: { repo: "library/debian", tag: "stable-slim", label: "Debian (stable, slim)" },
	alpine: { repo: "library/alpine", tag: "latest", label: "Alpine Linux" },
};

/** Installed right after unpacking so git, curl and TLS work from the start. */
const BASE_PACKAGES: Record<Distro, string> = {
	debian:
		"apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git openssh-client less procps",
	alpine: "apk add --no-cache bash ca-certificates curl git openssh-client less",
};

interface Meta {
	distro: Distro;
	image: string;
	installedAt: number;
}

export class Container {
	private readonly root: string;
	private readonly rootfs: string;
	private readonly metaFile: string;

	constructor(filesDir: string) {
		this.root = join(filesDir, "linux");
		this.rootfs = process.env.ANDROPI_ROOTFS ?? join(this.root, "rootfs");
		this.metaFile = join(this.root, "container.json");
	}

	private meta(): Meta | null {
		try {
			return JSON.parse(readFileSync(this.metaFile, "utf8"));
		} catch {
			return null;
		}
	}

	/** The `box` launcher pi uses as its shell while the container is on. */
	get shellPath() {
		return join(process.env.PI_CODING_AGENT_DIR ?? "", "bin", "box");
	}

	status(currentShell: string | undefined) {
		const meta = this.meta();
		const installed = !!meta && existsSync(join(this.rootfs, "etc"));
		return {
			installed,
			distro: installed ? meta!.distro : null,
			image: installed ? meta!.image : null,
			installedAt: installed ? meta!.installedAt : null,
			enabled: installed && currentShell === this.shellPath,
			distros: Object.entries(IMAGES).map(([id, i]) => ({ id, label: i.label })),
		};
	}

	/** Keeps the container's resolver in line with the app's DNS choice. */
	setNameservers(mode: DnsMode) {
		const etc = join(this.rootfs, "etc");
		if (!existsSync(etc)) return;
		rmSync(join(etc, "resolv.conf"), { force: true });
		writeFileSync(join(etc, "resolv.conf"), NAMESERVERS[mode].map((ip) => `nameserver ${ip}`).join("\n") + "\n");
	}

	async install(distro: Distro, log: Log, dns: DnsMode = "cloudflare") {
		const image = IMAGES[distro];
		if (!image) throw new Error(`Unknown distro: ${distro}`);
		rmSync(this.rootfs, { recursive: true, force: true });
		rmSync(this.metaFile, { force: true });
		mkdirSync(this.rootfs, { recursive: true });

		log(`Pulling ${image.repo.replace("library/", "")}:${image.tag} (${PLATFORM.label})…`);
		const layers = await this.resolveLayers(image.repo, image.tag);
		for (const [i, layer] of layers.entries()) {
			log(`Layer ${i + 1}/${layers.length} · ${(layer.size / 1e6).toFixed(1)} MB`);
			await this.extractLayer(image.repo, layer, log);
		}

		log("Configuring…");
		this.configure(distro);
		this.setNameservers(dns);
		writeFileSync(
			this.metaFile,
			JSON.stringify({ distro, image: `${image.repo.replace("library/", "")}:${image.tag}`, installedAt: Date.now() }),
		);

		log("Installing base tools (git, curl, ssh, certificates)…");
		await run("box", ["-c", BASE_PACKAGES[distro]], { cwd: process.env.HOME ?? "/", log });
		log("Container ready");
		return this.status(undefined);
	}

	remove() {
		rmSync(this.rootfs, { recursive: true, force: true });
		rmSync(this.metaFile, { force: true });
	}

	// -------------------------------------------------------------------------
	// Docker Hub (anonymous pulls)

	private token?: string;

	private async registry(repo: string, path: string, accept?: string) {
		if (!this.token) {
			const res = await fetch(
				`https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull`,
			);
			this.token = ((await res.json()) as any).token;
		}
		const res = await fetch(`https://registry-1.docker.io/v2/${repo}/${path}`, {
			headers: { Authorization: `Bearer ${this.token}`, ...(accept ? { Accept: accept } : {}) },
		});
		if (!res.ok) throw new Error(`Registry ${path}: ${res.status} ${res.statusText}`);
		return res;
	}

	private async resolveLayers(repo: string, tag: string) {
		this.token = undefined;
		const index = (await (
			await this.registry(
				repo,
				`manifests/${tag}`,
				"application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json",
			)
		).json()) as any;
		const arm = (index.manifests ?? []).find(
			(m: any) =>
				m.platform?.os === "linux" &&
				m.platform?.architecture === PLATFORM.architecture &&
				(!PLATFORM.variant || m.platform?.variant === PLATFORM.variant),
		);
		if (!arm) throw new Error(`No ${PLATFORM.label} image available`);
		const manifest = (await (
			await this.registry(
				repo,
				`manifests/${arm.digest}`,
				"application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json",
			)
		).json()) as any;
		return (manifest.layers as any[]).map((l) => ({ digest: l.digest as string, size: l.size as number }));
	}

	private async extractLayer(repo: string, layer: { digest: string; size: number }, log: Log) {
		const res = await this.registry(repo, `blobs/${layer.digest}`);
		let received = 0;
		let lastPct = -1;
		const counted = Readable.fromWeb(res.body as any).on("data", (chunk: Buffer) => {
			received += chunk.length;
			const pct = Math.floor((received / layer.size) * 100);
			if (pct >= lastPct + 10 || pct === 100) {
				lastPct = pct;
				log(`Downloading: ${pct}%`);
			}
		});
		await untar(counted.pipe(createGunzip()), this.rootfs);
	}

	private configure(distro: Distro) {
		const etc = join(this.rootfs, "etc");
		mkdirSync(etc, { recursive: true });
		// Replace (not follow) whatever the image ships: often a symlink to /run.
		for (const [name, body] of [
			["resolv.conf", "nameserver 8.8.8.8\nnameserver 1.1.1.1\n"],
			["hosts", "127.0.0.1 localhost\n::1 localhost ip6-localhost\n"],
		]) {
			rmSync(join(etc, name), { force: true });
			writeFileSync(join(etc, name), body);
		}
		const tmp = join(this.rootfs, "tmp");
		mkdirSync(tmp, { recursive: true });
		chmodSync(tmp, 0o1777);
		if (distro === "debian") {
			// apt drops privileges to _apt for downloads; under proot that user can't write.
			mkdirSync(join(etc, "apt/apt.conf.d"), { recursive: true });
			writeFileSync(
				join(etc, "apt/apt.conf.d/99andropi"),
				'APT::Sandbox::User "root";\nAcquire::Retries "3";\nAPT::Install-Recommends "false";\n',
			);
		}
	}
}

// ---------------------------------------------------------------------------
// Minimal tar reader (ustar + GNU long names + PAX paths). Hardlinks become
// copies: Android app storage does not allow link().

async function untar(stream: AsyncIterable<Buffer>, dest: string) {
	let buf: Buffer = Buffer.alloc(0);
	let longName: string | null = null;
	let longLink: string | null = null;
	let pax: Record<string, string> = {};
	const links: [string, string][] = [];

	const next = async function* () {
		for await (const chunk of stream) yield chunk as Buffer;
	};
	const it = next();
	const need = async (n: number) => {
		while (buf.length < n) {
			const { value, done } = await it.next();
			if (done) return false;
			buf = buf.length ? Buffer.concat([buf, value]) : value;
		}
		return true;
	};
	const take = (n: number) => {
		const out = buf.subarray(0, n);
		buf = buf.subarray(n);
		return out;
	};
	const str = (b: Buffer, off: number, len: number) => {
		const s = b.subarray(off, off + len);
		const z = s.indexOf(0);
		return (z >= 0 ? s.subarray(0, z) : s).toString("utf8");
	};
	const safe = (name: string) => {
		const clean = normalize(name.replace(/^\.?\/+/, "")).replace(/^(\.\.(\/|$))+/, "");
		return clean && clean !== "." ? join(dest, clean) : null;
	};

	while (await need(512)) {
		const h = take(512);
		if (h.every((b) => b === 0)) continue;
		const size = parseInt(str(h, 124, 12).trim() || "0", 8);
		const type = String.fromCharCode(h[156] || 48);
		const prefix = str(h, 345, 155);
		let name = longName ?? pax.path ?? (prefix ? `${prefix}/${str(h, 0, 100)}` : str(h, 0, 100));
		const linkName = longLink ?? pax.linkpath ?? str(h, 157, 100);
		const mode = parseInt(str(h, 100, 8).trim() || "644", 8) & 0o7777;
		const padded = Math.ceil(size / 512) * 512;
		if (!(await need(padded))) throw new Error("Truncated layer");
		const data = take(padded).subarray(0, size);

		if (type === "L") {
			longName = str(data, 0, size);
			continue;
		}
		if (type === "K") {
			longLink = str(data, 0, size);
			continue;
		}
		if (type === "x" || type === "g") {
			if (type === "x") pax = parsePax(data);
			continue;
		}
		longName = longLink = null;
		pax = {};

		// OCI whiteouts only matter across layers; these images are single-layer.
		const base = name.split("/").pop() ?? "";
		if (base.startsWith(".wh.")) continue;
		const path = safe(name);
		if (!path) continue;
		mkdirSync(dirname(path), { recursive: true });

		switch (type) {
			case "5":
				mkdirSync(path, { recursive: true });
				chmodSync(path, mode | 0o700);
				break;
			case "2":
				rmSync(path, { force: true });
				symlinkSync(linkName, path);
				break;
			case "1":
				links.push([path, linkName]);
				break;
			case "0":
			case "7":
			case "\0":
				rmSync(path, { force: true });
				writeFileSync(path, data);
				chmodSync(path, mode | 0o600);
				break;
			default:
				// Devices and FIFOs: /dev is bind-mounted from the host.
				break;
		}
	}
	for (const [path, target] of links) {
		const from = safe(target);
		if (!from || !existsSync(from) || lstatSync(from).isDirectory()) continue;
		rmSync(path, { force: true });
		copyFileSync(from, path);
		chmodSync(path, statSync(from).mode & 0o7777);
	}
}

function parsePax(data: Buffer) {
	const out: Record<string, string> = {};
	let pos = 0;
	while (pos < data.length) {
		const sp = data.indexOf(0x20, pos);
		if (sp < 0) break;
		const len = parseInt(data.subarray(pos, sp).toString(), 10);
		if (!len) break;
		const record = data.subarray(sp + 1, pos + len - 1).toString("utf8");
		const eq = record.indexOf("=");
		if (eq > 0) out[record.slice(0, eq)] = record.slice(eq + 1);
		pos += len;
	}
	return out;
}
