#!/usr/bin/env node
// End-to-end output contract: the real CLI and broker against a scripted helper,
// so every public result shape is checked without a live desktop. act-ui exits zero unless
// an action provably failed: an outcome no evidence could judge is reported as unverified,
// and an action that closes its own root is proof in itself and hands over the app's next root.
// Offscreen elements outside the view come and go as one summary line, not a line each.
import assert from "node:assert/strict";
import { once } from "node:events";
import fs from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { buildBundle, brokerEnvironment, makeTemporaryRoot, runCli, spawnBroker, withTimeout } from "./lib/harness.mjs";
import { screenshotDirectory } from "../src/artifacts.ts";
import { HELPER_PROTOCOL_VERSION } from "../src/macos/helper.ts";
import { HELPER_ARCHITECTURE_VERSION, REQUIRED_HELPER_INVARIANTS } from "../src/macos/protocol.ts";

const APP = { pid: 4242, appName: "Fixture", bundleId: "com.example.fixture", isFrontmost: true };
const ROOT_DEFAULTS = { scaleFactor: 2, isMinimized: false, isOnscreen: true, isMain: false, isModal: false };
const MENU_BAR_ROOT = {
	...ROOT_DEFAULTS,
	kind: "menubar",
	rootRef: "menubar1",
	pid: 4242,
	appName: "Fixture",
	bundleId: "com.example.fixture",
	title: "Fixture",
	role: "AXMenuBar",
	subrole: "",
	framePoints: { x: 0, y: 0, w: 2560, h: 30 },
	zOrder: 900,
	isFocused: false,
};
const MENU_ROOT = {
	...ROOT_DEFAULTS,
	kind: "menu",
	rootRef: "menu9",
	pid: 4242,
	appName: "Fixture",
	bundleId: "com.example.fixture",
	title: "文件",
	role: "AXMenu",
	subrole: "",
	framePoints: { x: 110, y: 31, w: 237, h: 425 },
	zOrder: 0,
	isFocused: true,
};
const EMPTY_APP = { pid: 4343, appName: "Empty", bundleId: "com.example.empty", isFrontmost: false };
const DESKTOP_APP = { pid: 4444, appName: "Desktop", bundleId: "com.example.desktop", isFrontmost: false };
const ROWS_APP = { pid: 4545, appName: "Rows", bundleId: "com.example.rows", isFrontmost: false };
const ROWS_WINDOW_ID = 9002;
const WEB_APP = { pid: 4646, appName: "Web", bundleId: "com.example.web", isFrontmost: false };
const WEB_WINDOW_ID = 9003;
// An exact app name wins over the longer names that contain it.
const TWIN_APP = { pid: 4747, appName: "Twin", bundleId: "com.example.twin", isFrontmost: false };
const TWIN_TESTING_APP = { pid: 4848, appName: "Twin for Testing", bundleId: "com.example.twin.testing", isFrontmost: false };
/** Keys the scripted helper answers with an outcome no evidence could judge, and with a proven no-op. */
const UNJUDGED_KEY = "F19";
const NO_OP_KEY = "F18";
/** A key after which the scripted app grows, then drops, a batch of offscreen menu items. */
const NOISE_KEY = "F17";
const NOISE_ITEMS = 30;
const SHEET_ROOT = {
	...ROOT_DEFAULTS,
	kind: "sheet",
	rootRef: "sheet1",
	windowId: 9101,
	pid: 4242,
	appName: "Fixture",
	bundleId: "com.example.fixture",
	title: "警告",
	role: "AXSheet",
	subrole: "",
	framePoints: { x: 40, y: 40, w: 420, h: 160 },
	zOrder: 0,
	isFocused: true,
};
const SHEET_BUTTONS = [["sheet-save", "仍要保存"], ["sheet-cancel", "取消"]];
let sheetOpen = false;
/** Where the noise items hang, and whether they are there. */
const noise = { parentWire: undefined, present: false };
const WINDOW_ID = 9001;
const fixture = JSON.parse(await fs.readFile(new URL("./fixtures/textedit-outline.json", import.meta.url), "utf8"));
const rowFixture = JSON.parse(await fs.readFile(new URL("./fixtures/finder-outline.json", import.meta.url), "utf8"));
const webFixture = JSON.parse(await fs.readFile(new URL("./fixtures/chrome-outline.json", import.meta.url), "utf8"));

function toWireNode(node) {
	return { ...node, ref: node.wireRef, wireRef: undefined, children: node.children.map(toWireNode) };
}

const outline = toWireNode(fixture.root);
const rowOutline = toWireNode(rowFixture.root);
const webOutline = toWireNode(webFixture.root);
const values = new Map();
const actRequests = [];

function noiseItem(index) {
	return { ref: `noise-${index}`, role: "AXMenuItem", title: `菜单项 ${index}`, actions: ["AXPress"], canPress: true, offscreen: true, children: [] };
}

function withValues(node) {
	const extra = noise.present && node.ref === noise.parentWire ? Array.from({ length: NOISE_ITEMS }, (_, index) => noiseItem(index)) : [];
	return { ...node, value: values.get(node.ref) ?? node.value, children: [...node.children.map(withValues), ...extra] };
}

const SHEET_OUTLINE = {
	ref: "sheet",
	role: "AXSheet",
	children: SHEET_BUTTONS.map(([ref, title]) => ({ ref, role: "AXButton", title, actions: ["AXPress"], canPress: true, children: [] })),
};

function sheetLook(request) {
	if (!sheetOpen) throw Object.assign(new Error(`Window ${request.windowId} is not available for capture`), { code: "window_not_found" });
	return {
		lookId: `look-${++lookCounter}`,
		capturedAt: Date.now() / 1000,
		window: { windowId: SHEET_ROOT.windowId, rootRef: SHEET_ROOT.rootRef, kind: "sheet", framePoints: SHEET_ROOT.framePoints, scaleFactor: 2, isModal: false, role: "AXSheet", subrole: "" },
		outline: SHEET_OUTLINE,
		timings: {},
	};
}

let lookCounter = 0;

function plainWindow(pid) {
	const app = [WEB_APP, TWIN_APP, TWIN_TESTING_APP].find((candidate) => candidate.pid === pid);
	return {
		...ROOT_DEFAULTS,
		kind: "window",
		windowRef: `w${pid}`,
		rootRef: `w${pid}`,
		windowId: pid === WEB_APP.pid ? WEB_WINDOW_ID : pid,
		pid,
		appName: app.appName,
		bundleId: app.bundleId,
		title: `${app.appName} window`,
		role: "AXWindow",
		subrole: "AXStandardWindow",
		framePoints: { x: 0, y: 0, w: 1200, h: 800 },
		zOrder: 3,
		isMain: true,
		isFocused: false,
		metadata: { pairing: { confidence: "exact", score: 110 } },
	};
}

function actOutcome(request) {
	if (SHEET_BUTTONS.some(([ref]) => ref === request.target.ref)) {
		sheetOpen = false;
		return { outcome: "unknown", performed: { delivery: "ax" }, rootDelta: [{ change: "closed", ...SHEET_ROOT }] };
	}
	const keys = request.action === "keypress" ? request.params.keys : [];
	if (keys.includes(NOISE_KEY)) {
		noise.present = !noise.present;
		values.set(request.target.ref, noise.present ? "noise on" : "noise off");
		return { outcome: "worked", performed: { delivery: "ax" }, verification: { source: "ax", field: "value" } };
	}
	if (keys.includes(UNJUDGED_KEY)) return { outcome: "unknown", performed: { delivery: "ax" } };
	if (keys.includes(NO_OP_KEY)) return { outcome: "didnt", performed: { delivery: request.policy === "foreground" ? "hid" : "pid" } };
	return {
		outcome: "worked",
		performed: { delivery: "ax" },
		verification: { source: "ax", field: "value", from: "0", to: "1" },
		rootDelta: request.action === "press" ? [{ change: "appeared", ...MENU_ROOT }] : undefined,
	};
}

function helperResult(request) {
	switch (request.cmd) {
		case "diagnostics": return {
			protocolVersion: HELPER_PROTOCOL_VERSION,
			architectureVersion: HELPER_ARCHITECTURE_VERSION,
			invariants: [...REQUIRED_HELPER_INVARIANTS],
			pid: process.pid,
		};
		case "checkPermissions": return {
			accessibility: true,
			screenRecordingCapturable: true,
			screenRecordingPreflight: true,
			source: { attribution: "helper-app", pid: process.pid },
		};
		case "listApps": return { apps: [APP, EMPTY_APP, DESKTOP_APP, ROWS_APP, WEB_APP, TWIN_APP, TWIN_TESTING_APP] };
		case "listRoots": return {
			roots: request.pid === EMPTY_APP.pid ? [] : [WEB_APP, TWIN_APP, TWIN_TESTING_APP].some((app) => app.pid === request.pid) ? [plainWindow(request.pid)] : request.pid === ROWS_APP.pid ? [{
				kind: "window",
				windowRef: "w2",
				rootRef: "w2",
				windowId: ROWS_WINDOW_ID,
				pid: ROWS_APP.pid,
				appName: ROWS_APP.appName,
				title: "MacBook Pro",
				role: "AXWindow",
				subrole: "AXStandardWindow",
				framePoints: { x: 0, y: 0, w: 920, h: 556 },
				scaleFactor: 2,
				zOrder: 2,
				isMinimized: false,
				isOnscreen: true,
				isMain: true,
				isFocused: false,
				isModal: false,
				metadata: { pairing: { confidence: "exact", score: 110 } },
			}] : request.pid === DESKTOP_APP.pid ? [{
				kind: "window",
				windowRef: "desktop",
				rootRef: "desktop",
				pid: DESKTOP_APP.pid,
				appName: DESKTOP_APP.appName,
				title: "",
				role: "AXScrollArea",
				subrole: "AXDesktop",
				framePoints: { x: 0, y: 0, w: 2560, h: 1440 },
				scaleFactor: 2,
				zOrder: 99,
				isMinimized: false,
				isOnscreen: true,
				isMain: false,
				isFocused: false,
				isModal: false,
				metadata: { pairing: { confidence: "low", score: -60 } },
			}] : [{
				kind: "window",
				windowRef: "w1",
				rootRef: "w1",
				windowId: WINDOW_ID,
				pid: APP.pid,
				appName: APP.appName,
				bundleId: APP.bundleId,
				title: "未命名2",
				role: "AXWindow",
				subrole: "AXStandardWindow",
				framePoints: { x: 0, y: 0, w: 586, h: 488 },
				scaleFactor: 2,
				zOrder: 1,
				isMinimized: false,
				isOnscreen: true,
				isMain: true,
				isFocused: true,
				isModal: false,
				metadata: { pairing: { confidence: "exact", score: 110 } },
			}, MENU_BAR_ROOT, ...(sheetOpen ? [SHEET_ROOT] : [])],
		};
		case "getFrontmost": return { ...APP, windowId: WINDOW_ID, windowTitle: "未命名2" };
		case "look": if (request.windowId === SHEET_ROOT.windowId) return sheetLook(request); return {
			lookId: `look-${++lookCounter}`,
			capturedAt: Date.now() / 1000,
			window: {
				windowId: request.windowId,
				rootRef: "w1",
				kind: "window",
				framePoints: { x: 0, y: 0, w: 586, h: 488 },
				scaleFactor: 2,
				isModal: false,
				role: "AXWindow",
				subrole: "AXStandardWindow",
				metadata: { pairing: { confidence: "exact", score: 110 } },
			},
			image: request.includeImage === false ? undefined : { jpegBase64: Buffer.from("fixture-image").toString("base64"), mimeType: "image/jpeg", width: 586, height: 488 },
			outline: request.windowId === ROWS_WINDOW_ID ? rowOutline : request.windowId === WEB_WINDOW_ID ? webOutline : withValues(outline),
			timings: {},
		};
		case "act": {
			actRequests.push(request);
			if (request.action === "setText") values.set(request.target.ref, request.params.text);
			return actOutcome(request);
		}
		case "axWaitFor": {
			const wanted = request.value ?? request.text;
			const present = [...values.values()].some((value) => value === wanted);
			return present ? { found: true, nodeCount: 1 } : { found: false, timedOut: true, nodeCount: 1 };
		}
		case "axReadText": return { text: "fixture text slice", offset: 0, limit: 4000, totalChars: 18, hasMore: false };
		default: return {};
	}
}

const temporaryRoot = await makeTemporaryRoot("contract");
const helperSocketPath = path.join(temporaryRoot, "helper.sock");
const brokerSocketPath = path.join(temporaryRoot, "broker.sock");
const helper = net.createServer((socket) => {
	socket.setEncoding("utf8");
	let buffer = "";
	socket.on("error", () => undefined);
	socket.on("data", (chunk) => {
		buffer += chunk;
		for (;;) {
			const newline = buffer.indexOf("\n");
			if (newline < 0) return;
			const request = JSON.parse(buffer.slice(0, newline));
			buffer = buffer.slice(newline + 1);
			try {
				socket.write(`${JSON.stringify({ id: request.id, ok: true, result: helperResult(request) })}\n`);
			} catch (error) {
				socket.write(`${JSON.stringify({ id: request.id, ok: false, error: { code: error.code, message: error.message } })}\n`);
			}
		}
	});
});

const env = { ...brokerEnvironment(brokerSocketPath, 30_000), BCU_SOCKET_PATH: helperSocketPath };

function json(result, label, forbiddenKeys = ["ok", "result", "text", "details"]) {
	assert.equal(result.code, 0, `${label} exited ${result.code}: ${result.stderr}`);
	const parsed = JSON.parse(result.stdout);
	for (const forbidden of forbiddenKeys) {
		assert(!(forbidden in parsed), `${label} JSON still carries a '${forbidden}' wrapper key`);
	}
	return parsed;
}

async function shotFiles() {
	return new Set(await fs.readdir(screenshotDirectory()).catch(() => []));
}

await buildBundle();
await new Promise((resolve, reject) => {
	helper.once("error", reject);
	helper.listen(helperSocketPath, resolve);
});
const broker = spawnBroker(env);
try {
	await withTimeout(once(broker.ready, "data"), "the contract broker to signal readiness", 20_000);

	const shotsBefore = await shotFiles();
	const observed = json(await runCli(["observe-ui", "--app", "Fixture", "--json"], { env }), "observe-ui");
	assert.deepEqual(Object.keys(observed).sort(), ["nodes", "root", "shown", "stateId", "total"], "observe-ui result shape drifted");
	assert.equal(observed.total, 47, "observe-ui did not report the full outline size");
	assert.equal(observed.nodes[0].role, "window", "observe-ui did not project the root as a short role word");
	assert(!/"AX|_NS:/.test(JSON.stringify(observed)), "observe-ui JSON leaks raw accessibility names");
	assert.deepEqual([...await shotFiles()].filter((file) => !shotsBefore.has(file)), [], "observe-ui wrote a screenshot without being asked");

	const text = await runCli(["observe-ui", "--app", "Fixture"], { env });
	assert.match(text.stdout.split("\n")[0], /^@r\d+ Fixture — 未命名2 · state [0-9a-z]{8} · 47 nodes, \d+ shown$/, `observe-ui header drifted: ${text.stdout.split("\n")[0]}`);

	const stateId = observed.stateId;
	const searched = json(await runCli(["search-ui", "--state", stateId, "--role", "textarea", "--json"], { env }), "search-ui");
	assert.deepEqual(Object.keys(searched).sort(), ["matches", "stateId", "total"], "search-ui result shape drifted");
	assert.equal(searched.stateId, stateId, "search-ui returned another state");
	assert.equal(searched.matches[0].role, "textarea", "search-ui did not match the projected role word");
	assert(Array.isArray(searched.matches[0].path), "search-ui match has no ancestry path");

	const editorRef = searched.matches[0].ref;
	const byCapability = json(await runCli(["search-ui", "--state", stateId, "--action", "setText", "--json"], { env }), "search-ui --action");
	assert(byCapability.matches.some((match) => match.ref === editorRef), "search-ui --action setText did not find the editable element");
	assert(byCapability.matches.every((match) => match.caps.includes("setText")), `search-ui --action setText returned elements without that capability: ${byCapability.matches.map((match) => `${match.ref} ${match.role}`).join(", ")}`);
	const expanded = json(await runCli(["expand-ui", "--state", stateId, "--ref", "@e3", "--json"], { env }), "expand-ui");
	assert.deepEqual(Object.keys(expanded).sort(), ["nodes", "ref", "stateId"], "expand-ui result shape drifted");
	assert(expanded.nodes.length > 1, "expand-ui returned no subtree");

	const inspected = json(await runCli(["inspect-ui", "--state", stateId, "--ref", editorRef, "--json"], { env }), "inspect-ui");
	assert.deepEqual(Object.keys(inspected).sort(), ["node", "stateId"], "inspect-ui result shape drifted");
	assert.equal(inspected.node.role, "AXTextArea", "inspect-ui hid the raw accessibility role");

	const read = json(await runCli(["read-text", "--state", stateId, "--ref", editorRef, "--json"], { env }), "read-text", ["ok", "result", "details"]);
	assert.deepEqual(Object.keys(read).sort(), ["limit", "offset", "ref", "stateId", "text", "total"], "read-text result shape drifted");

	const acted = json(await runCli(["act-ui", "--state", stateId, "--expect-value", "typed", "--timeout", "1000", "--json", "-"], {
		env,
		input: `${JSON.stringify([{ action: "setText", ref: editorRef, text: "typed" }])}\n`,
	}), "act-ui");
	assert.deepEqual(Object.keys(acted).sort(), ["baseStateId", "changes", "delivery", "outcome", "stateId", "verification"], "act-ui result shape drifted");
	assert.equal(acted.baseStateId, stateId, "act-ui lost the base state");
	assert.equal(acted.verification.status, "verified", "act-ui did not verify its postcondition");
	assert.deepEqual(acted.verification.evidence, { source: "ax", field: "value", from: "0", to: "1" }, "act-ui dropped the helper's evidence for the outcome");
	assert.deepEqual(acted.changes, [{ type: "updated", ref: editorRef, fields: { value: "typed" } }], "act-ui successor diff drifted");

	const waited = json(await runCli(["wait-for", "--state", acted.stateId, "--text", "typed", "--timeout", "1000", "--json"], { env }), "wait-for");
	assert.equal(waited.found, true, "wait-for did not report the satisfied condition");
	assert.match(waited.stateId, /^[0-9a-z]{8}$/, "wait-for did not return a short successor stateId");
	assert.notEqual(waited.stateId, acted.stateId, "wait-for did not return a successor state");

	const timedOut = await runCli(["wait-for", "--state", acted.stateId, "--text", "__never__", "--timeout", "200", "--json"], { env });
	assert.equal(timedOut.code, 8, `wait-for timeout exited ${timedOut.code}`);
	assert.equal(timedOut.stdout, "", "wait-for timeout wrote to stdout");
	assert.match(timedOut.stderr, /^error action_timeout: /m, "wait-for timeout is not a stable action_timeout");

	// A root the action opened is the agent's next target, so act-ui hands it over with a
	// usable @r instead of making the agent race find-roots for it.
	const opened = json(await runCli(["act-ui", "--state", acted.stateId, "--json", "-"], {
		env,
		input: `${JSON.stringify([{ action: "press", ref: editorRef }])}\n`,
	}), "act-ui press");
	const actedText = await runCli(["act-ui", "--state", opened.stateId, "-"], {
		env,
		input: `${JSON.stringify([{ action: "press", ref: editorRef }])}\n`,
	});
	assert.equal(actedText.code, 0, `act-ui text view exited ${actedText.code}: ${actedText.stderr}`);
	assert.match(actedText.stdout.split("\n")[0], / · worked via ax · value 0→1$/, `act-ui does not show why the helper called it worked: ${actedText.stdout.split("\n")[0]}`);
	assert.equal(opened.roots?.length, 1, `act-ui did not report the root the action opened: ${JSON.stringify(opened.roots)}`);
	assert.match(opened.roots[0].ref, /^@r\d+$/, `act-ui reported a root without a usable ref: ${JSON.stringify(opened.roots[0])}`);
	assert.deepEqual(
		{ kind: opened.roots[0].kind, app: opened.roots[0].app, title: opened.roots[0].title },
		{ kind: "menu", app: "Fixture", title: "文件" },
		`act-ui root delta drifted: ${JSON.stringify(opened.roots[0])}`,
	);
	assert(actedText.stdout.includes(`+ root ${opened.roots[0].ref} menu "文件"`), `act-ui text view hides the new root: ${actedText.stdout}`);

	// An action no evidence could judge is not a failure: it exits zero, says it is
	// unverified, and hands over the successor state, naming the absence of any change.
	const freshState = async () => json(await runCli(["observe-ui", "--app", "Fixture", "--json"], { env }), "observe-ui").stateId;
	const unjudgedKey = [{ action: "keypress", ref: editorRef, keys: [UNJUDGED_KEY] }];
	const unverifiedText = await runCli(["act-ui", "--state", await freshState(), "-"], { env, input: `${JSON.stringify(unjudgedKey)}\n` });
	assert.equal(unverifiedText.code, 0, `an unjudged keypress exited ${unverifiedText.code}: ${unverifiedText.stderr}`);
	const [unverifiedLine, unverifiedChanges] = unverifiedText.stdout.split("\n");
	assert.match(unverifiedLine, /^state [0-9a-z]{8} ← [0-9a-z]{8} · unverified via ax$/, `an unjudged keypress does not say it is unverified: ${unverifiedLine}`);
	assert.equal(unverifiedChanges, "(no element changes)", `an unjudged keypress does not say nothing changed: ${unverifiedText.stdout}`);
	const unverifiedState = unverifiedLine.split(" ")[1];
	const unverified = json(await runCli(["act-ui", "--state", unverifiedState, "--json", "-"], { env, input: `${JSON.stringify(unjudgedKey)}\n` }), "act-ui unjudged --json");
	assert.equal(unverified.outcome, "unknown", `an unjudged keypress reported outcome ${unverified.outcome}`);
	assert.deepEqual(unverified.changes, [], `an unjudged keypress reported changes: ${JSON.stringify(unverified.changes)}`);

	// Steps of one array do not depend on each other's UI: an unjudged step does not stop the
	// next, and a step that provably did nothing stops the array and fails it.
	actRequests.length = 0;
	const continued = json(await runCli(["act-ui", "--state", unverified.stateId, "--json", "-"], {
		env,
		input: `${JSON.stringify([...unjudgedKey, { action: "setText", ref: editorRef, text: "after unknown" }])}\n`,
	}), "act-ui unjudged then setText");
	assert(actRequests.some((request) => request.action === "setText"), "an unjudged step stopped the rest of the array");
	assert.equal(continued.outcome, "unknown", `an array with an unjudged step reported outcome ${continued.outcome}`);
	assert.deepEqual(continued.changes, [{ type: "updated", ref: editorRef, fields: { value: "after unknown" } }], `the array's successor lost the later step: ${JSON.stringify(continued.changes)}`);
	actRequests.length = 0;
	const stopped = await runCli(["act-ui", "--state", continued.stateId, "--json", "-"], {
		env,
		input: `${JSON.stringify([{ action: "keypress", ref: editorRef, keys: [NO_OP_KEY] }, { action: "setText", ref: editorRef, text: "never" }])}\n`,
	});
	assert.equal(stopped.code, 9, `a step that did nothing exited ${stopped.code}: ${stopped.stderr}`);
	assert.equal(stopped.stdout, "", "a failed array wrote a result to stdout");
	assert.match(stopped.stderr, /^error action_failed: /m, `a step that did nothing is not action_failed: ${stopped.stderr}`);
	assert(!actRequests.some((request) => request.action === "setText"), "a step that did nothing did not stop the array");

	// A satisfied postcondition is the evidence an unjudged action lacked.
	const expected = json(await runCli(["act-ui", "--state", await freshState(), "--expect-value", "after unknown", "--scope", editorRef, "--timeout", "1000", "--json", "-"], {
		env,
		input: `${JSON.stringify(unjudgedKey)}\n`,
	}), "act-ui unjudged with a satisfied postcondition");
	assert.equal(expected.outcome, "worked", `a satisfied postcondition reported outcome ${expected.outcome}`);
	assert.equal(expected.verification.status, "verified", "a satisfied postcondition was not reported as verified");

	// Offscreen elements outside the view — menu items a menu grows and drops — are one
	// summary line; the change the view shows still has its own line.
	const noiseView = json(await runCli(["observe-ui", "--app", "Fixture", "--json"], { env }), "observe-ui for noise");
	const folded = noiseView.nodes.find((node) => node.hidden);
	assert(folded, "the fixture view folds nothing to hang offscreen items under");
	noise.parentWire = json(await runCli(["inspect-ui", "--state", noiseView.stateId, "--ref", folded.ref, "--json"], { env }), "inspect-ui folded").node.wireRef;
	const noiseKey = `${JSON.stringify([{ action: "keypress", ref: editorRef, keys: [NOISE_KEY] }])}\n`;
	const grown = await runCli(["act-ui", "--state", noiseView.stateId, "-"], { env, input: noiseKey });
	assert.equal(grown.code, 0, `the noise keypress exited ${grown.code}: ${grown.stderr}`);
	assert.equal(grown.stdout.split("\n").filter((line) => /^[+-] @e/.test(line)).length, 0, `offscreen items outside the view were listed one by one:\n${grown.stdout}`);
	assert.match(grown.stdout, new RegExp(`^~ ${editorRef} ="noise on"$`, "m"), `the visible change lost its line:\n${grown.stdout}`);
	assert.match(grown.stdout, new RegExp(`^… offscreen elements outside the view: ${NOISE_ITEMS} added$`, "m"), `the offscreen additions are not summarized:\n${grown.stdout}`);
	const dropped = await runCli(["act-ui", "--state", grown.stdout.split(" ")[1], "--json", "-"], { env, input: noiseKey });
	assert.equal(dropped.code, 0, `the second noise keypress exited ${dropped.code}: ${dropped.stderr}`);
	const droppedResult = JSON.parse(dropped.stdout);
	assert.deepEqual(droppedResult.changes, [{ type: "updated", ref: editorRef, fields: { value: "noise off" } }], `offscreen removals leaked into changes: ${JSON.stringify(droppedResult.changes)}`);
	assert.deepEqual(droppedResult.offscreen, { added: 0, removed: NOISE_ITEMS }, `the offscreen removals are not counted: ${JSON.stringify(droppedResult.offscreen)}`);

	// Pressing a button that closes its own sheet is proof the press landed. The result names
	// the closed root, hands over the app's next root with a view of it, and later steps of
	// the array are not sent to a root that no longer exists.
	const openSheet = async () => {
		sheetOpen = true;
		const sheet = json(await runCli(["find-roots", "--app", "Fixture", "--kind", "sheet", "--json"], { env }), "find-roots --kind sheet").roots[0];
		assert(sheet, "the scripted sheet is not listed");
		const view = json(await runCli(["observe-ui", "--root", sheet.ref, "--json"], { env }), "observe-ui sheet");
		const button = (name) => view.nodes.find((node) => node.name === name)?.ref;
		return { sheet, view, save: button("仍要保存"), cancel: button("取消") };
	};
	let sheet = await openSheet();
	const closedJson = json(await runCli(["act-ui", "--state", sheet.view.stateId, "--json", "-"], { env, input: `${JSON.stringify([{ action: "press", ref: sheet.save }])}\n` }), "act-ui closing its sheet");
	assert.equal(closedJson.outcome, "worked", `closing the sheet reported ${closedJson.outcome}`);
	assert.deepEqual(closedJson.verification.evidence, { source: "root", field: "closed" }, `closing the sheet was judged on ${JSON.stringify(closedJson.verification.evidence)}`);
	assert.deepEqual(closedJson.closed?.root, { ref: sheet.sheet.ref, kind: "sheet", app: "Fixture", title: "警告" }, `the closed root is not named: ${JSON.stringify(closedJson.closed)}`);
	assert.deepEqual({ kind: closedJson.next?.kind, title: closedJson.next?.title }, { kind: "window", title: "未命名2" }, `the next root is not the sheet's window: ${JSON.stringify(closedJson.next)}`);
	assert.match(closedJson.stateId, /^[0-9a-z]{8}$/, "closing the sheet returned no successor state");
	assert(closedJson.nodes?.length > 0, "closing the sheet returned no view of the next root");
	const nextView = json(await runCli(["observe-ui", "--root", closedJson.next.ref, "--json"], { env }), "observe-ui next root");
	assert.equal(nextView.root.title, "未命名2", "the next root ref does not observe the sheet's window");

	sheet = await openSheet();
	actRequests.length = 0;
	const closedText = await runCli(["act-ui", "--state", sheet.view.stateId, "-"], {
		env,
		input: `${JSON.stringify([{ action: "press", ref: sheet.save }, { action: "press", ref: sheet.cancel }])}\n`,
	});
	assert.equal(closedText.code, 0, `closing the sheet from an array exited ${closedText.code}: ${closedText.stderr}`);
	assert.deepEqual(actRequests.map((request) => request.target.ref), ["sheet-save"], `a step was sent to the closed sheet: ${JSON.stringify(actRequests.map((request) => request.target))}`);
	const closedLines = closedText.stdout.split("\n");
	assert.match(closedLines[0], new RegExp(`^state [0-9a-z]{8} ← ${sheet.view.stateId} · worked via ax · root closed$`), `the result line does not say the root closed: ${closedLines[0]}`);
	assert.equal(closedLines[1], `- root ${sheet.sheet.ref} sheet "警告"`, `the closed root is not the line after the result: ${closedText.stdout}`);
	assert(closedLines.includes("skipped 1 later step: its root closed"), `the skipped step is not reported: ${closedText.stdout}`);
	assert(closedLines.some((line) => /^next root @r\d+ window "未命名2"$/.test(line)), `the next root is not named: ${closedText.stdout}`);

	const menuBars = json(await runCli(["find-roots", "--app", "Fixture", "--kind", "menubar", "--json"], { env }), "find-roots --kind menubar");
	assert.equal(menuBars.roots.length, 1, `find-roots did not expose the app's menu bar as a root: ${JSON.stringify(menuBars.roots)}`);
	assert.equal(menuBars.roots[0].windowId, undefined, "a menu bar root claimed a window id it does not have");
	// A menu bar only answers in the frontmost app, so it is offered when it is asked for.
	const byKind = json(await runCli(["find-roots", "--kind", "menubar", "--json"], { env }), "find-roots --kind menubar without an app");
	assert.equal(byKind.roots.length, 1, `--kind menubar alone did not list the menu bar: ${JSON.stringify(byKind.roots)}`);
	for (const [label, args] of [["undirected", ["find-roots", "--json"]], ["by app", ["find-roots", "--app", "Fixture", "--kind", "window", "--json"]]]) {
		const listed = json(await runCli(args, { env }), `find-roots ${label}`);
		assert(listed.roots.every((root) => root.kind !== "menubar"), `${label} find-roots listed menu bars nobody asked for: ${JSON.stringify(listed.roots)}`);
	}

	// Pairing confidence is how the helper matched an AX window to a window server window;
	// it is not something an agent chooses a root by.
	const listedText = await runCli(["find-roots", "--app", "Fixture"], { env });
	assert.equal(listedText.code, 0, `find-roots exited ${listedText.code}: ${listedText.stderr}`);
	assert(!/pairing/.test(listedText.stdout), `find-roots text still shows pairing: ${listedText.stdout}`);
	assert(json(await runCli(["find-roots", "--app", "Fixture", "--json"], { env }), "find-roots --json").roots.every((root) => !("pairing" in root)), "find-roots JSON still carries pairing");

	const twin = json(await runCli(["find-roots", "--app", "Twin", "--json"], { env }), "find-roots --app Twin");
	assert.deepEqual(twin.roots.map((root) => root.app), ["Twin"], `--app Twin also matched the longer names containing it: ${JSON.stringify(twin.roots.map((root) => root.app))}`);
	const twins = json(await runCli(["find-roots", "--app", "Twi", "--json"], { env }), "find-roots --app Twi");
	assert.deepEqual(twins.roots.map((root) => root.app).sort(), ["Twin", "Twin for Testing"], `without an exact name --app stopped matching partially: ${JSON.stringify(twins.roots.map((root) => root.app))}`);

	// search-ui --action finds what the view promises, not every raw action name that contains the word.
	const web = json(await runCli(["observe-ui", "--app", "Web", "--json"], { env }), "observe-ui --app Web");
	for (const capability of ["scroll", "menu"]) {
		const found = json(await runCli(["search-ui", "--state", web.stateId, "--action", capability, "--limit", "50", "--json"], { env }), `search-ui --action ${capability}`);
		assert(found.matches.every((match) => match.caps.includes(capability)), `search-ui --action ${capability} returned elements without that capability: ${found.matches.map((match) => `${match.ref} ${match.role} {${match.caps}}`).join(", ")}`);
	}
	assert.deepEqual(
		json(await runCli(["search-ui", "--state", web.stateId, "--action", "scroll", "--json"], { env }), "search-ui --action scroll").matches.map((match) => match.name),
		["Scroll area"],
		"search-ui --action scroll did not find the web scroll area",
	);

	const noWindow = await runCli(["observe-ui", "--app", "Empty", "--json"], { env });
	assert.equal(noWindow.code, 6, `running app without windows exited ${noWindow.code}: ${noWindow.stderr}`);
	assert.match(noWindow.stderr, /^error window_stale: App 'Empty' is running but has no controllable window/m, `window_stale message drifted: ${noWindow.stderr}`);

	const rows = json(await runCli(["observe-ui", "--app", "Rows", "--json"], { env }), "observe-ui --app Rows");
	const rowsText = await runCli(["observe-ui", "--app", "Rows"], { env });
	assert.equal(rowsText.stdout.trim().split("\n").length, rows.nodes.length + 1, "JSON nodes and the text view disagree about what is shown");
	const rowMatch = json(await runCli(["search-ui", "--state", rows.stateId, "--text", "下载", "--json"], { env }), "search-ui --text").matches[0];
	assert.equal(rowMatch.role, "row", `folded sidebar entry projected as ${rowMatch.role}`);
	assert.deepEqual(rowMatch.caps, ["open"], "folded sidebar entry lost its merged capability");
	assert.equal(rowMatch.owners?.open, "@e55", `capability owner is not reported: ${JSON.stringify(rowMatch.owners)}`);
	const inspectedRow = json(await runCli(["inspect-ui", "--state", rows.stateId, "--ref", rowMatch.ref, "--json"], { env }), "inspect-ui row");
	assert.equal(inspectedRow.owners?.open, "@e55", "inspect-ui does not expose the capability owner");
	actRequests.length = 0;
	const pressed = await runCli(["act-ui", "--state", rows.stateId, "--json", "-"], {
		env,
		input: `${JSON.stringify([{ action: "press", ref: rowMatch.ref }])}\n`,
	});
	assert.equal(pressed.code, 0, `press on a folded row exited ${pressed.code}: ${pressed.stderr}`);
	assert.equal(actRequests.at(-1)?.target?.ref, "e1411", `press was delivered to ${JSON.stringify(actRequests.at(-1)?.target)} instead of the element that owns the capability`);

	const desktopOnly = await runCli(["observe-ui", "--app", "Desktop", "--json"], { env });
	assert.equal(desktopOnly.code, 6, `app with only a desktop root exited ${desktopOnly.code}: ${desktopOnly.stderr}`);
	assert.match(desktopOnly.stderr, /^error window_stale: /m, "a desktop-only app is not reported as window_stale");

	const fused = json(await runCli(["observe-ui", "--app", "Fixture", "--mode", "fused", "--json"], { env }), "observe-ui --mode fused");
	assert.equal(fused.image.mime, "image/jpeg", "fused observation returned no image reference");
	assert.equal((await fs.stat(fused.image.path)).size > 0, true, "fused observation wrote no screenshot file");
	await fs.rm(fused.image.path, { force: true });

	console.log("PASS public result contract: 8 commands, projected views, verified act diff, window_stale and action_timeout");
} finally {
	await runCli(["stop"], { env }).catch(() => undefined);
	if (broker.process.exitCode === null) broker.process.kill("SIGTERM");
	await new Promise((resolve) => helper.close(resolve));
	await fs.rm(temporaryRoot, { recursive: true, force: true });
}
