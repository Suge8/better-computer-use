#!/usr/bin/env node
// typeText inserts exactly the text it was given, whatever input method the user has on.
// The gate switches the session to Simplified Pinyin, and then to the user's own input
// source when that is another Chinese, Japanese or Korean input method, restoring the
// user's source afterwards; a source that is not enabled is skipped, and so is the gate
// when neither is. Under each it types the same ASCII text, which such an input method
// would otherwise turn into candidates, into three background targets: a TextEdit
// document, a web input in Chrome, and a self-drawn input with no accessible content that
// takes text only through the input method, clicked into first the way an agent types
// into WeChat. Each target's own record must gain exactly the text, and a stand-in for the
// user's front app keeps the front, its key window and the keyboard throughout.
// A cell only proves something while the input method is composing: a third-party input
// method in its English mode passes letters straight through, so a bcu that typed physical
// keys would pass as well. So before the cells of each source the gate presses a few letter
// keys into the self-drawn input with `--foreground`, because an input method composes only
// for the front app (the same keys posted to a background app arrive as plain letters), and
// requires them to become uncommitted composition rather than the letters themselves;
// otherwise it skips that source's cells and says why. It then cancels the composition,
// leaving the input without marked text.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { launchChrome, pageSession, stopChrome } from "./lib/chrome.mjs";
import {
	residentEnvironment,
	desktop,
	inputSourceEnabled,
	killProcess,
	launchDrawnInput,
	launchKeyHolder,
	launchTextEdit,
	makeTemporaryRoot,
	monitorProcess,
	runCli,
	selectInputSource,
	stopTextEdit,
	waitForAxWindow,
	withTimeout,
} from "./lib/harness.mjs";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP IME typing (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The IME typing gate requires macOS.");

const PINYIN = "com.apple.inputmethod.SCIM.ITABC";
const TEXT = "bcu test 42";
/** Letter keys a composing input method turns into marked text instead of committing them. */
const PROBE_KEYS = ["b", "c", "u"];
const PAGE = `<!doctype html><meta charset="utf-8"><title>bcu ime fixture</title><input id="field" aria-label="IME field">`;

// Nothing switches the input source before the try whose finally restores the user's.
const userSource = await selectInputSource();
const pinyinEnabled = await inputSourceEnabled(PINYIN);
if (!pinyinEnabled) console.log(`SKIP ${PINYIN} cells (not enabled on this Mac)`);
const sources = [...(pinyinEnabled ? [PINYIN] : []), ...(userSource.cjk && userSource.id !== PINYIN ? [userSource.id] : [])];
if (sources.length === 0) {
	console.log("SKIP IME typing (neither Pinyin nor another CJK input method is enabled)");
	process.exit(0);
}

const root = await makeTemporaryRoot("ime-typing");
const env = residentEnvironment(path.join(root, "resident.sock"), 30_000);
const cells = [];
const skipped = [];
let holder;
let chrome;
let drawn;
let textEditPid;
let textEditMonitor;
let drawnTitle;
let drawnLog;
let drawnEvents;

async function bcu(args, input) {
	const result = await runCli([...args, "--json"], { input, env });
	if (result.code !== 0) throw new Error(`bcu ${args[0]} exited ${result.code}: ${result.stderr.trim()}`);
	return JSON.parse(result.stdout);
}

async function act(stateId, actions, flags = []) {
	return await bcu(["act-ui", "--state", stateId, ...flags, "-"], `${JSON.stringify(actions)}\n`);
}

async function rootOf(pid, title) {
	const found = await bcu(["find-roots", "--pid", String(pid), "--kind", "window"]);
	const window = found.roots.find((candidate) => candidate.title.startsWith(title));
	assert(window, `bcu found no window titled ${title}: ${found.roots.map((candidate) => candidate.title).join(", ")}`);
	return window.ref;
}

async function refFor(stateId, args) {
	const found = await bcu(["search-ui", "--state", stateId, ...args, "--limit", "1"]);
	assert(found.matches[0], `no match for ${args.join(" ")} in state ${stateId}`);
	return found.matches[0].ref;
}

/** The drawn input's uncommitted text after each change, and the text it committed. */
async function drawnRecords() {
	const marked = (await fs.readFile(drawnEvents, "utf8")).split("\n").filter((line) => line.startsWith("marked ")).map((line) => line.slice("marked ".length));
	return { marked, committed: await fs.readFile(drawnLog, "utf8") };
}

/** Clicks into the drawn input and runs `actions` there, in the background unless `flags` say otherwise. */
async function actInDrawnInput(actions, flags = []) {
	const state = await bcu(["observe-ui", "--root", await rootOf(drawn.pid, drawnTitle)]);
	const box = state.nodes.find((node) => node.role === "ocr" && node.name === "输入区");
	assert(box, `the drawn input was not read on screen: ${JSON.stringify(state.nodes.map((node) => [node.role, node.name]))}`);
	const { rect } = (await bcu(["inspect-ui", "--state", state.stateId, "--ref", box.ref])).node;
	return await act(state.stateId, [{ action: "click", x: rect.x + rect.w / 2, y: rect.y + rect.h / 2 }, ...actions], flags);
}

/**
 * Whether `source` composes the probe keys instead of committing them; the reason when it
 * does not. The composition is cancelled afterwards, and the input left without marked text.
 */
async function composes(source) {
	assert.equal((await selectInputSource(source)).id, source, `${source} did not become the input source`);
	const before = await drawnRecords();
	await actInDrawnInput(PROBE_KEYS.map((key) => ({ action: "keypress", keys: [key] })), ["--foreground"]);
	const pressed = await drawnRecords();
	const committed = pressed.committed.slice(before.committed.length);
	const marked = pressed.marked.slice(before.marked.length).at(-1) ?? "";
	await actInDrawnInput([{ action: "keypress", keys: ["Escape"] }], ["--foreground"]);
	const left = (await drawnRecords()).marked.at(-1) ?? "";
	assert.equal(left, "", `Escape did not cancel the ${source} composition; the drawn input still holds ${JSON.stringify(left)}`);
	if (committed.includes(PROBE_KEYS.join(""))) return `${source} committed the letter keys ${JSON.stringify(committed)} as typed: it is not composing (English mode?)`;
	if (!marked) return `${source} neither composed nor committed the letter keys (committed ${JSON.stringify(committed)})`;
	return undefined;
}

/** Runs one cell and records every promise it broke instead of stopping at the first. */
async function cell(source, name, run) {
	const failures = [];
	try {
		assert.equal((await selectInputSource(source)).id, source, `${source} did not become the input source`);
		const logged = (await holder.takeFront()).length;
		const before = await desktop();
		assert.equal(before.front, holder.pid, "the key holder did not take the front before the cell");
		const { result, before: had, after: has } = await run();
		const typed = has.startsWith(had) ? has.slice(had.length) : `${has} (replacing ${had})`;
		const after = await desktop();
		if (typed !== TEXT) failures.push(`the target received ${JSON.stringify(typed)}, want ${JSON.stringify(TEXT)}`);
		if (after.front !== before.front) failures.push(`front app changed ${before.front} → ${after.front}`);
		const lost = (await holder.logged()).slice(logged);
		if (lost.length) failures.push(`the user's front app lost its key window or activation: ${lost.join(", ")}`);
		if (after.x !== before.x || after.y !== before.y) failures.push(`real pointer moved (${before.x},${before.y}) → (${after.x},${after.y})`);
		if (result.delivery === "hid") failures.push("delivered as foreground HID input");
	} catch (error) {
		failures.push(error.message);
	}
	cells.push({ name, failures });
	console.log(`${failures.length ? "FAIL" : "PASS"} ${source}: ${name}${failures.map((failure) => `\n  - ${failure}`).join("")}`);
}

try {
	holder = await launchKeyHolder(root);

	const documentTitle = `bcu-ime-${randomUUID()}`;
	const documentPath = path.join(root, `${documentTitle}.txt`);
	await fs.writeFile(documentPath, "");
	textEditPid = await launchTextEdit(documentPath);
	textEditMonitor = await monitorProcess(textEditPid);
	await waitForAxWindow(textEditPid, textEditMonitor.exited, documentTitle);
	const pageUrl = `file://${path.join(root, "page.html")}`;
	await fs.writeFile(path.join(root, "page.html"), PAGE);
	chrome = await launchChrome(path.join(root, "profile"), pageUrl, (spawned) => { chrome = spawned; });
	const page = await pageSession(chrome, pageUrl);
	drawnTitle = `bcu drawn input ${randomUUID().slice(0, 8)}`;
	drawnLog = path.join(root, "drawn-input.log");
	drawnEvents = path.join(root, "drawn-input-events.log");
	drawn = await launchDrawnInput(root, drawnLog, drawnTitle, drawnEvents);
	await waitForAxWindow(drawn.pid, drawn.exited, drawnTitle);

	for (const source of sources) {
		const notComposing = await composes(source);
		if (notComposing) {
			console.log(`SKIP ${source} cells: ${notComposing}`);
			skipped.push(source);
			continue;
		}
		await cell(source, "TextEdit document", async () => {
			const document = await rootOf(textEditPid, documentTitle);
			const state = await bcu(["observe-ui", "--root", document]);
			const area = await refFor(state.stateId, ["--action", "typeText"]);
			// Refs belong to the state that minted them, so the successor finds the text area anew.
			const value = async (stateId) => (await bcu(["inspect-ui", "--state", stateId, "--ref", await refFor(stateId, ["--action", "typeText"])])).node.value ?? "";
			const before = await value(state.stateId);
			const result = await act(state.stateId, [{ action: "typeText", ref: area, text: TEXT }]);
			return { result, before, after: await value((await bcu(["observe-ui", "--root", document])).stateId) };
		});
		await cell(source, "Chrome web input", async () => {
			const window = await rootOf(chrome.child.pid, "bcu ime fixture");
			const first = await bcu(["observe-ui", "--root", window]);
			await bcu(["wait-for", "--state", first.stateId, "--text", "IME field", "--timeout", "10000"]);
			const state = await bcu(["observe-ui", "--root", window]);
			const value = async () => (await page.send("Runtime.evaluate", { expression: `document.getElementById("field").value`, returnByValue: true })).result.value;
			const before = await value();
			const result = await act(state.stateId, [{ action: "typeText", ref: await refFor(state.stateId, ["--text", "IME field", "--role", "textfield"]), text: TEXT }]);
			return { result, before, after: await value() };
		});
		await cell(source, "self-drawn input clicked into, then typed into its focus", async () => {
			const before = await fs.readFile(drawnLog, "utf8");
			const result = await actInDrawnInput([{ action: "typeText", text: TEXT }]);
			return { result, before, after: await fs.readFile(drawnLog, "utf8") };
		});
	}
	page.close();
} finally {
	const restored = await selectInputSource(userSource.id);
	console.log(`input source restored to ${restored.id}${restored.id === userSource.id ? "" : ` (was ${userSource.id})`}`);
	await stopChrome(chrome);
	if (drawn && killProcess(drawn.pid, "SIGTERM")) await withTimeout(drawn.exited, "the drawn input to exit", 5_000).catch(() => killProcess(drawn.pid));
	if (textEditPid) await stopTextEdit(textEditPid, textEditMonitor);
	if (holder && killProcess(holder.pid, "SIGTERM")) await withTimeout(holder.exited, "the key holder to exit", 5_000).catch(() => killProcess(holder.pid));
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(root, { recursive: true, force: true });
}

const failed = cells.filter((entry) => entry.failures.length);
console.log(`${cells.length - failed.length}/${cells.length} IME typing cells passed`);
if (failed.length || cells.length + skipped.length === 0) process.exit(1);
