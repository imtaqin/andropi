// Builds src/host.ts and packs it, with pi and all of its production
// dependencies, into android/app/src/main/assets/agent.zip.
//
// pi is not re-bundled: it loads OAuth flows and provider APIs through
// variable import specifiers relative to its own files, so it has to ship as
// an installed package. The host imports it from agent/node_modules.
import { execSync } from "node:child_process";
import { build } from "esbuild";
import { cpSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const assets = join(root, "android", "app", "src", "main", "assets");
const stage = join(root, "build", "agent-stage");
const out = join(stage, "out");
const piVersion = JSON.parse(
	readFileSync(join(here, "node_modules", "@earendil-works", "pi-coding-agent", "package.json"), "utf8"),
).version;

// 1. Production install of the same pi version into a clean staging dir.
rmSync(stage, { recursive: true, force: true });
mkdirSync(stage, { recursive: true });
writeFileSync(join(stage, "package.json"), JSON.stringify({ name: "andropi-agent", private: true, type: "module" }));
execSync(`npm install --omit=dev --ignore-scripts --no-audit --no-fund @earendil-works/pi-coding-agent@${piVersion}`, {
	cwd: stage,
	stdio: "inherit",
});

// 2. Drop what cannot run on Android or is never read at runtime.
// prebuilds: desktop-only .node clipboard helpers; pi-tui skips them when missing.
const dropDirs = new Set(["@esbuild", "@types", "examples", "test", "tests", "__tests__", ".github", "prebuilds"]);
const dropFile = (name) =>
	name.endsWith(".map") ||
	name.endsWith(".d.ts") ||
	name.endsWith(".d.mts") ||
	name.endsWith(".d.cts") ||
	name === "CHANGELOG.md" ||
	name === "npm-shrinkwrap.json";
function prune(dir) {
	for (const name of readdirSync(dir)) {
		const path = join(dir, name);
		if (statSync(path).isDirectory()) {
			if (dropDirs.has(name)) rmSync(path, { recursive: true, force: true });
			else prune(path);
		} else if (dropFile(name)) {
			rmSync(path);
		}
	}
}
prune(join(stage, "node_modules"));

// 3. Host script; pi stays an external import resolved from node_modules.
mkdirSync(out, { recursive: true });
await build({
	entryPoints: [join(here, "src", "host.ts")],
	outfile: join(out, "host.mjs"),
	bundle: true,
	platform: "node",
	format: "esm",
	target: "node24",
	external: ["@earendil-works/pi-coding-agent"],
	// Bundled CommonJS deps (the MCP SDK's cross-spawn) require() Node builtins.
	banner: { js: 'import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);' },
	logLevel: "warning",
});
cpSync(join(stage, "package.json"), join(out, "package.json"));
// Skills AndroPI ships with; the host seeds them into <agentDir>/skills.
cpSync(join(here, "skills"), join(out, "skills"), { recursive: true });
cpSync(join(stage, "node_modules"), join(out, "node_modules"), { recursive: true });

// 4. Ship as one archive: copying thousands of small files through
// AssetManager is slow, a single zip streams in one pass. The stamp lets the
// app re-extract only when the bundle changes.
const stamp = `${piVersion} ${Date.now()}`;
rmSync(join(assets, "agent"), { recursive: true, force: true });
mkdirSync(assets, { recursive: true });
execSync(
	`python -c "import shutil,sys; shutil.make_archive(sys.argv[1], 'zip', sys.argv[2])" "${join(assets, "agent")}" "${out}"`,
	{ stdio: "inherit" },
);
writeFileSync(join(assets, "agent.stamp"), stamp);
const size = statSync(join(assets, "agent.zip")).size / 1e6;
console.log(`agent bundle (pi ${piVersion}, ${size.toFixed(1)} MB zip) -> ${assets}`);
