/**
 * Tolerant tool arguments. Some models fill optional parameters with
 * Python-ish placeholders ("None", "null") or send numbers as strings, which
 * pi's strict schema validation rejects ("offset: must be number"). This
 * cleans arguments against each tool's schema before validation runs.
 */

const EMPTY = new Set(["none", "null", "undefined", "nil", "nan", ""]);
const LENIENT = Symbol.for("andropi.lenient");

export function cleanArguments(args: unknown, schema: any): unknown {
	if (!args || typeof args !== "object" || Array.isArray(args) || !schema?.properties) return args;
	const out: Record<string, unknown> = { ...(args as Record<string, unknown>) };
	const required = new Set<string>(schema.required ?? []);
	for (const [key, prop] of Object.entries<any>(schema.properties)) {
		if (!(key in out)) continue;
		const value = out[key];
		const type = prop?.type ?? prop?.anyOf?.find((s: any) => s.type && s.type !== "null")?.type;
		if (typeof value === "string" && type !== "string" && EMPTY.has(value.trim().toLowerCase())) {
			if (!required.has(key)) delete out[key];
			continue;
		}
		if (typeof value === "string" && type === "string" && !required.has(key) && /^(none|null|undefined)$/i.test(value.trim())) {
			delete out[key];
			continue;
		}
		if ((type === "number" || type === "integer") && typeof value === "string" && value.trim() !== "" && !Number.isNaN(Number(value))) {
			out[key] = Number(value);
		} else if (type === "boolean" && typeof value === "string" && /^(true|false)$/i.test(value.trim())) {
			out[key] = value.trim().toLowerCase() === "true";
		} else if (type === "object" && value && typeof value === "object") {
			out[key] = cleanArguments(value, prop);
		}
	}
	return out;
}

function makeLenient(tool: any) {
	if (!tool || tool[LENIENT]) return tool;
	const original = tool.prepareArguments?.bind(tool);
	tool.prepareArguments = (args: unknown) => {
		const cleaned = cleanArguments(args, tool.parameters);
		return original ? original(cleaned) : cleaned;
	};
	tool[LENIENT] = true;
	return tool;
}

/** Applies to the agent's current tools and to any set later (reloads, tool changes). */
export function installLenientTools(agent: any) {
	const state = agent?.state;
	if (!state || state[LENIENT]) return;
	const desc = Object.getOwnPropertyDescriptor(state, "tools");
	if (desc?.get && desc.set) {
		Object.defineProperty(state, "tools", {
			configurable: true,
			enumerable: desc.enumerable,
			get: desc.get,
			set(value: any[]) {
				desc.set!.call(this, Array.isArray(value) ? value.map(makeLenient) : value);
			},
		});
	}
	state[LENIENT] = true;
	for (const tool of state.tools ?? []) makeLenient(tool);
}
