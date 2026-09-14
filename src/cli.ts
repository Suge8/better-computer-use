import { realpathSync } from "node:fs";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";
import { brokerHandshakeIfRunning, requestBroker, requestRunningBroker } from "./client.ts";
import {
	CLI_COMMAND_NAMES,
	type ActEvidence,
	type ActParams,
	type ActResult,
	type Change,
	type CliCommandExecutor,
	type CliCommandName,
	type CliCommandParams,
	type CliCommandResults,
	type ExpandResult,
	type ExpandUiParams,
	type FindParams,
	type FindRootsResult,
	type InspectResult,
	type InspectUiParams,
	type ObserveParams,
	type ObserveResult,
	type ReadTextParams,
	type ReadTextResult,
	type RootInfo,
	type SearchResult,
	type SearchUiParams,
	type UiAction,
	type WaitForParams,
	type WaitForResult,
} from "./contract.ts";
import { BcuError, formatCliError, normalizeCliError } from "./errors.ts";
import { renderNode, renderNodes, renderObservation, type ProjectedNode } from "./projection.ts";
import { renderChanges } from "./view.ts";

function executor<Name extends CliCommandName>(name: Name): CliCommandExecutor<Name> {
	return async (params, signal) => await requestBroker<CliCommandResults[Name]>(name, params, signal);
}

export const CLI_COMMANDS = {
	"find-roots": executor("find-roots"),
	"observe-ui": executor("observe-ui"),
	"search-ui": executor("search-ui"),
	"expand-ui": executor("expand-ui"),
	"inspect-ui": executor("inspect-ui"),
	"act-ui": executor("act-ui"),
	"read-text": executor("read-text"),
	"wait-for": executor("wait-for"),
} satisfies { [Name in CliCommandName]: CliCommandExecutor<Name> };

type OptionKind = "string" | "number" | "boolean";

interface OptionSpec {
	key: string;
	kind: OptionKind;
	values?: readonly string[];
	doc: string;
}

interface ParsedOptions {
	values: Record<string, string | number | boolean>;
	positionals: string[];
}

interface CommandSpec<Name extends CliCommandName> {
	summary: string;
	arguments?: string;
	options: Record<string, OptionSpec>;
	parse(parsed: ParsedOptions): CliCommandParams[Name] | Promise<CliCommandParams[Name]>;
	render(result: CliCommandResults[Name]): string;
}

const STATE: OptionSpec = { key: "stateId", kind: "string", doc: "stateId from observe-ui (required)" };
const REF: OptionSpec = { key: "ref", kind: "string", doc: "element ref from the same state, e.g. @e12 (required)" };
const IMAGE: OptionSpec = { key: "image", kind: "string", values: ["never", "always"], doc: "write a screenshot artifact (default never)" };
const TIMEOUT: OptionSpec = { key: "timeoutMs", kind: "number", doc: "condition timeout in ms (default 10000, max 60000)" };
const SCOPE: OptionSpec = { key: "scope", kind: "string", doc: "limit the condition to this element subtree, e.g. @e12" };

function invalid(message: string): never {
	throw new BcuError("invalid_arguments", message);
}

function parseOptions(args: string[], specs: Record<string, OptionSpec>): ParsedOptions {
	const values: ParsedOptions["values"] = {};
	const positionals: string[] = [];
	for (let index = 0; index < args.length; index += 1) {
		const argument = args[index];
		if (!argument.startsWith("--")) {
			positionals.push(argument);
			continue;
		}
		const spec = specs[argument];
		if (!spec) invalid(`Unknown option '${argument}'.`);
		if (spec.key in values) invalid(`Option '${argument}' may be supplied only once.`);
		if (spec.kind === "boolean") {
			values[spec.key] = true;
			continue;
		}
		const raw = args[++index];
		if (raw === undefined || raw.startsWith("--")) invalid(`Option '${argument}' requires a value.`);
		if (spec.kind === "number") {
			const value = Number(raw);
			if (!Number.isFinite(value)) invalid(`Option '${argument}' requires a number.`);
			values[spec.key] = value;
		} else {
			if (spec.values && !spec.values.includes(raw)) invalid(`Option '${argument}' must be one of: ${spec.values.join(", ")}.`);
			values[spec.key] = raw;
		}
	}
	return { values, positionals };
}

function noPositionals(parsed: ParsedOptions): void {
	if (parsed.positionals.length > 0) invalid(`Unexpected argument '${parsed.positionals[0]}'.`);
}

function required(values: ParsedOptions["values"], key: string, option: string): string {
	const value = values[key];
	if (typeof value !== "string" || !value.trim()) invalid(`Option '${option}' is required.`);
	return value.trim();
}

function optionalString(values: ParsedOptions["values"], key: string): string | undefined {
	const value = values[key];
	return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function optionalNumber(values: ParsedOptions["values"], key: string): number | undefined {
	const value = values[key];
	return typeof value === "number" ? value : undefined;
}

const ACTIONS = new Set<UiAction["action"]>(["press", "click", "doubleClick", "setText", "typeText", "keypress", "scroll", "drag", "moveMouse", "wait"]);

async function readStdin(): Promise<string> {
	let input = "";
	process.stdin.setEncoding("utf8");
	for await (const chunk of process.stdin) input += chunk;
	return input;
}

async function readActions(): Promise<UiAction[]> {
	let parsed: unknown;
	try {
		parsed = JSON.parse(await readStdin());
	} catch (error) {
		invalid(`act-ui stdin must be a JSON action array: ${error instanceof Error ? error.message : String(error)}`);
	}
	if (!Array.isArray(parsed)) invalid("act-ui stdin must contain a JSON action array.");
	for (const action of parsed) {
		if (!action || typeof action !== "object" || !("action" in action) || !ACTIONS.has((action as UiAction).action)) {
			invalid("Every act-ui item must be an object with a supported action name.");
		}
	}
	return parsed as UiAction[];
}

function rootLine(root: RootInfo): string {
	const flags = [
		root.focused ? "focused" : undefined,
		root.main ? "main" : undefined,
		root.modal ? "modal" : undefined,
		root.onscreen ? "onscreen" : undefined,
		root.minimized ? "minimized" : undefined,
	].filter(Boolean).join(" ");
	const id = root.windowId ? `id ${root.windowId}` : "no window id";
	return `${root.ref} ${root.kind} ${root.app} ${JSON.stringify(root.title)} · pid ${root.pid} · ${id} · ${root.frame.x},${root.frame.y} ${root.frame.w}x${root.frame.h} · ${flags}${root.pairing ? ` · pairing ${root.pairing}` : ""}`;
}

function successorLines(result: { changes?: Change[]; nodes?: ProjectedNode[] }): string {
	if (result.nodes) return renderNodes(result.nodes);
	if (!result.changes) return "";
	return renderChanges(result.changes) || "(no element changes)";
}

/** The helper's reason for the outcome, as it reported it. */
function evidenceWords(evidence: ActEvidence | undefined): string {
	if (!evidence) return "";
	if (evidence.field && evidence.from !== undefined && evidence.to !== undefined) return ` · ${evidence.field} ${evidence.from}→${evidence.to}`;
	return ` · ${evidence.field ?? evidence.source}`;
}

function imageLine(image?: { path: string; width: number; height: number }): string {
	return image ? `image ${image.path} (${image.width}x${image.height})` : "";
}

const COMMANDS: { [Name in CliCommandName]: CommandSpec<Name> } = {
	"find-roots": {
		summary: "List controllable roots: windows, sheets, dialogs and open menus.",
		options: {
			"--query": { key: "query", kind: "string", doc: "match app name or window title" },
			"--app": { key: "app", kind: "string", doc: "restrict to one app name or bundle id" },
			"--bundle-id": { key: "bundleId", kind: "string", doc: "restrict to one exact bundle id" },
			"--pid": { key: "pid", kind: "number", doc: "restrict to one process id" },
			"--kind": { key: "kind", kind: "string", values: ["window", "menubar", "menu", "sheet", "popover", "dialog"], doc: "restrict to one root kind; menubar roots are listed only when this or an app names them" },
		},
		parse: (parsed) => {
			noPositionals(parsed);
			return parsed.values as FindParams;
		},
		render: (result: FindRootsResult) => result.roots.length
			? result.roots.map(rootLine).join("\n")
			: "no roots are visible to bcu",
	},
	"observe-ui": {
		summary: "Observe one root and return a stateId with the projected element tree.",
		options: {
			"--app": { key: "app", kind: "string", doc: "app name or bundle id" },
			"--window-title": { key: "windowTitle", kind: "string", doc: "exact or partial window title" },
			"--root": { key: "root", kind: "string", doc: "@r ref from find-roots, or a numeric window id" },
			"--mode": { key: "mode", kind: "string", values: ["semantic", "fused"], doc: "semantic: accessibility only (default); fused: also capture an image and OCR" },
			"--image": IMAGE,
			"--read-text": { key: "readText", kind: "string", values: ["auto", "always", "never"], doc: "OCR policy (default never in semantic, auto in fused)" },
		},
		parse: (parsed) => {
			noPositionals(parsed);
			return parsed.values as ObserveParams;
		},
		render: (result: ObserveResult) => [renderObservation(result), imageLine(result.image)].filter(Boolean).join("\n"),
	},
	"search-ui": {
		summary: "Search the saved outline of one state, including elements the view folded away.",
		options: {
			"--state": STATE,
			"--text": { key: "text", kind: "string", doc: "substring of any name, value or OCR text" },
			"--role": { key: "role", kind: "string", doc: "role word, e.g. button, textfield, row" },
			"--action": { key: "action", kind: "string", doc: "capability, e.g. press, setText, scroll" },
			"--limit": { key: "limit", kind: "number", doc: "maximum matches to return (default 12, max 50)" },
		},
		parse: (parsed) => {
			noPositionals(parsed);
			required(parsed.values, "stateId", "--state");
			return parsed.values as SearchUiParams;
		},
		render: (result: SearchResult) => [
			`${result.matches.length} of ${result.total} matches · state ${result.stateId}`,
			...result.matches.map((match) => `${renderNode({ ...match, depth: 0 })}${match.path.length ? ` in ${match.path.at(-1)}` : ""}`),
		].join("\n"),
	},
	"expand-ui": {
		summary: "Expand one element of a saved state, walking the live UI when the subtree was cut short.",
		options: {
			"--state": STATE,
			"--ref": REF,
			"--depth": { key: "depth", kind: "number", doc: "levels to unfold below the element (default 3, max 8)" },
		},
		parse: (parsed) => {
			noPositionals(parsed);
			return {
				stateId: required(parsed.values, "stateId", "--state"),
				ref: required(parsed.values, "ref", "--ref"),
				depth: optionalNumber(parsed.values, "depth"),
			} satisfies ExpandUiParams;
		},
		render: (result: ExpandResult) => [`${result.ref} · state ${result.stateId}`, renderNodes(result.nodes)].filter(Boolean).join("\n"),
	},
	"inspect-ui": {
		summary: "Print every raw accessibility field of one element, including the ones the projection hides.",
		options: {
			"--state": STATE,
			"--ref": REF,
		},
		parse: (parsed) => {
			noPositionals(parsed);
			return {
				stateId: required(parsed.values, "stateId", "--state"),
				ref: required(parsed.values, "ref", "--ref"),
			} satisfies InspectUiParams;
		},
		render: (result: InspectResult) => JSON.stringify(result.node, null, 2),
	},
	"act-ui": {
		summary: "Run a checked action array from stdin against one state and return the successor state.",
		arguments: "-",
		options: {
			"--state": STATE,
			"--headless": { key: "headless", kind: "boolean", doc: "never activate, focus or move the pointer physically" },
			"--image": IMAGE,
			"--expect-text": { key: "expectText", kind: "string", doc: "postcondition: this text must appear" },
			"--expect-role": { key: "expectRole", kind: "string", doc: "postcondition: an element with this role must appear" },
			"--expect-value": { key: "expectValue", kind: "string", doc: "postcondition: an element must hold this exact value" },
			"--expect-gone": { key: "expectGone", kind: "boolean", doc: "invert the postcondition: it must disappear" },
			"--scope": SCOPE,
			"--timeout": TIMEOUT,
		},
		parse: async (parsed) => {
			if (parsed.positionals.length !== 1 || parsed.positionals[0] !== "-") invalid("act-ui requires '-' and reads its JSON action array from stdin.");
			const stateId = required(parsed.values, "stateId", "--state");
			const text = optionalString(parsed.values, "expectText");
			const role = optionalString(parsed.values, "expectRole");
			const value = optionalString(parsed.values, "expectValue");
			const scope = optionalString(parsed.values, "scope");
			const gone = parsed.values.expectGone === true;
			const timeoutMs = optionalNumber(parsed.values, "timeoutMs");
			if ((gone || scope || timeoutMs !== undefined) && !text && !role && !value) {
				invalid("--expect-gone, --scope and --timeout require --expect-text, --expect-role, or --expect-value.");
			}
			return {
				stateId,
				actions: await readActions(),
				headless: parsed.values.headless === true || undefined,
				image: parsed.values.image as ActParams["image"],
				expect: text || role || value ? { text, role, value, scope, gone: gone || undefined, timeoutMs } : undefined,
			} satisfies ActParams;
		},
		render: (result: ActResult) => {
			const verified = result.verification.status === "verified"
				? ` · verified${result.verification.preexisting ? " (preexisting)" : ""}`
				: "";
			return [
				`state ${result.stateId} ← ${result.baseStateId} · ${result.outcome} via ${result.delivery}${evidenceWords(result.verification.evidence)}${verified}`,
				...(result.roots ?? []).map((root) => `+ root ${root.ref} ${root.kind} ${JSON.stringify(root.title)}`),
				successorLines(result),
				imageLine(result.image),
			].filter(Boolean).join("\n");
		},
	},
	"read-text": {
		summary: "Read the full text of one element, a slice at a time.",
		options: {
			"--state": STATE,
			"--ref": REF,
			"--offset": { key: "offset", kind: "number", doc: "first character to read (default 0)" },
			"--limit": { key: "limit", kind: "number", doc: "characters to read (default 4000, max 100000)" },
		},
		parse: (parsed) => {
			noPositionals(parsed);
			return {
				stateId: required(parsed.values, "stateId", "--state"),
				ref: required(parsed.values, "ref", "--ref"),
				offset: optionalNumber(parsed.values, "offset"),
				limit: optionalNumber(parsed.values, "limit"),
			} satisfies ReadTextParams;
		},
		render: (result: ReadTextResult) => `${result.ref} ${result.offset}-${result.offset + result.text.length} of ${result.total}\n${result.text}`,
	},
	"wait-for": {
		summary: "Wait for text or a role to appear or disappear, then return the successor state.",
		options: {
			"--state": STATE,
			"--text": { key: "text", kind: "string", doc: "text that must appear" },
			"--role": { key: "role", kind: "string", doc: "role word that must appear" },
			"--scope": SCOPE,
			"--gone": { key: "gone", kind: "boolean", doc: "wait for the condition to disappear instead" },
			"--timeout": TIMEOUT,
		},
		parse: (parsed) => {
			noPositionals(parsed);
			required(parsed.values, "stateId", "--state");
			if (!optionalString(parsed.values, "text") && !optionalString(parsed.values, "role")) invalid("wait-for requires --text or --role.");
			return parsed.values as WaitForParams;
		},
		render: (result: WaitForResult) => [
			`state ${result.stateId} · ${result.gone ? "gone" : "found"}`,
			successorLines(result),
		].filter(Boolean).join("\n"),
	},
};

const PLAIN_COMMANDS = {
	status: "Report broker status without starting it.",
	doctor: "Start and diagnose broker, helper, permissions and config.",
	setup: "Register and verify macOS permissions.",
	stop: "Stop the broker if it is running.",
} as const;

function optionHelp(options: Record<string, OptionSpec>): string[] {
	return Object.entries(options).map(([flag, spec]) => {
		const value = spec.kind === "boolean" ? "" : spec.values ? ` ${spec.values.join("|")}` : spec.kind === "number" ? " <n>" : " <value>";
		const label = `${flag}${value}`;
		return `  ${label.padEnd(26)}${label.length > 26 ? " " : ""}${spec.doc}`;
	});
}

function commandHelp(name: CliCommandName): string {
	const spec = COMMANDS[name];
	return [
		`bcu ${name}${spec.arguments ? ` ${spec.arguments}` : ""} [options]`,
		"",
		spec.summary,
		"",
		"Options:",
		...optionHelp(spec.options),
		`  ${"--json".padEnd(26)}emit one JSON object on stdout`,
	].join("\n");
}

function overviewHelp(): string {
	const commands = CLI_COMMAND_NAMES.map((name) => `  ${name.padEnd(16)}${COMMANDS[name].summary}`);
	const plain = Object.entries(PLAIN_COMMANDS).map(([name, summary]) => `  ${name.padEnd(16)}${summary}`);
	return [
		"bcu <command> [options]",
		"",
		"Commands:",
		...commands,
		...plain,
		"",
		"Every command takes --json for one JSON object on stdout, and --help for its own options.",
		"Failures write nothing to stdout and report 'error <code>' plus 'recovery' on stderr.",
	].join("\n");
}

function write(result: unknown, json: boolean, text: string): void {
	process.stdout.write(json ? `${JSON.stringify(result)}\n` : text ? `${text.trimEnd()}\n` : "");
}

async function runCommand<Name extends CliCommandName>(name: Name, args: string[], json: boolean): Promise<void> {
	const spec = COMMANDS[name];
	const params = await spec.parse(parseOptions(args, spec.options));
	const result = await executor(name)(params);
	write(result, json, spec.render(result));
}

async function runStatus(json: boolean): Promise<void> {
	const broker = await brokerHandshakeIfRunning();
	const result = broker ? { running: true, ...broker } : { running: false };
	write(result, json, broker ? `broker running · pid ${broker.pid} · protocol ${broker.brokerVersion}` : "broker stopped");
}

interface DoctorResult {
	broker: { pid: number };
	helper: { protocolVersion: number };
	permissions?: { accessibility: boolean; screenRecording: boolean };
}

async function runDoctor(json: boolean): Promise<void> {
	const result = await requestBroker<DoctorResult>("doctor", {});
	const permissions = result.permissions
		? `permissions: accessibility=${result.permissions.accessibility} screenRecording=${result.permissions.screenRecording}`
		: "permissions: not required";
	write(result, json, `broker ok · pid ${result.broker.pid}\nhelper ok · protocol ${result.helper.protocolVersion}\n${permissions}`);
}

async function runSetup(json: boolean): Promise<void> {
	if (!process.stdin.isTTY || !process.stderr.isTTY) {
		throw new BcuError("permission_missing", "bcu setup requires an interactive terminal so you can grant macOS permissions.");
	}
	const registered = await requestBroker<Record<string, unknown>>("setup", { phase: "register" });
	process.stderr.write("Enable bcu in System Settings → Privacy & Security → Accessibility and Screen Recording.\n");
	const terminal = createInterface({ input: process.stdin, output: process.stderr });
	try { await terminal.question("Press Enter after both switches are enabled: "); } finally { terminal.close(); }
	const result = await requestBroker<Record<string, unknown>>("setup", { phase: "complete" });
	write({ registered, ...result }, json, "setup: permissions granted");
}

async function runStop(json: boolean): Promise<void> {
	const result = await requestRunningBroker<{ stopped: boolean; pid: number }>("stop", {});
	write(result ?? { stopped: true, alreadyStopped: true }, json, result ? `broker stopped · pid ${result.pid}` : "broker already stopped");
}

function internalRequest(args: string[]): { command: string; params: Record<string, unknown> } {
	if (args.length !== 2) invalid("Internal request requires a command and one JSON object.");
	let params: unknown;
	try { params = JSON.parse(args[1]); } catch (error) { invalid(`Internal request JSON is invalid: ${String(error)}`); }
	if (!params || typeof params !== "object" || Array.isArray(params)) invalid("Internal request args must be a JSON object.");
	return { command: args[0], params: params as Record<string, unknown> };
}

function isCommandName(value: string): value is CliCommandName {
	return (CLI_COMMAND_NAMES as readonly string[]).includes(value);
}

export async function main(args = process.argv.slice(2)): Promise<void> {
	if (process.platform !== "darwin") {
		throw new BcuError("unsupported_platform", `bcu controls macOS apps and does not support platform '${process.platform}'.`);
	}
	const [internalCommand, ...internalArgs] = args;
	if (internalCommand === "__serve") {
		if (internalArgs.length > 0) invalid("__serve accepts no arguments.");
		const { serveBroker } = await import("./broker.ts");
		await serveBroker();
		return;
	}
	if (internalCommand === "__request") {
		const request = internalRequest(internalArgs);
		process.stdout.write(`${JSON.stringify(await requestBroker(request.command, request.params))}\n`);
		return;
	}
	const json = args.includes("--json");
	const help = args.includes("--help") || args.includes("-h");
	const [command, ...commandArgs] = args.filter((argument) => argument !== "--json" && argument !== "--help" && argument !== "-h");
	if (!command) {
		process.stdout.write(`${overviewHelp()}\n`);
		return;
	}
	if (isCommandName(command)) {
		if (help) {
			process.stdout.write(`${commandHelp(command)}\n`);
			return;
		}
		return await runCommand(command, commandArgs, json);
	}
	if (command in PLAIN_COMMANDS) {
		if (help) {
			process.stdout.write(`bcu ${command}\n\n${PLAIN_COMMANDS[command as keyof typeof PLAIN_COMMANDS]}\n\nOptions:\n  --json                    emit one JSON object on stdout\n`);
			return;
		}
		if (commandArgs.length > 0) invalid(`${command} accepts no options except --json.`);
		if (command === "status") return await runStatus(json);
		if (command === "doctor") return await runDoctor(json);
		if (command === "setup") return await runSetup(json);
		return await runStop(json);
	}
	if (help) {
		process.stdout.write(`${overviewHelp()}\n`);
		return;
	}
	invalid(`Unknown command '${command}'. Run 'bcu --help'.`);
}

function isEntrypoint(): boolean {
	if (!process.argv[1]) return false;
	try {
		return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
	} catch {
		return false;
	}
}

if (isEntrypoint()) {
	try {
		await main();
	} catch (error) {
		const normalized = normalizeCliError(error);
		process.stderr.write(formatCliError(normalized));
		process.exitCode = normalized.exitCode;
	}
}
