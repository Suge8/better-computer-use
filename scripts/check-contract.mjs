#!/usr/bin/env node
// End-to-end output contract: the real CLI and broker against a scripted helper,
// so every public result shape is checked without a live desktop.
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
const EMPTY_APP = { pid: 4343, appName: "Empty", bundleId: "com.example.empty", isFrontmost: false };
const DESKTOP_APP = { pid: 4444, appName: "Desktop", bundleId: "com.example.desktop", isFrontmost: false };
const ROWS_APP = { pid: 4545, appName: "Rows", bundleId: "com.example.rows", isFrontmost: false };
const ROWS_WINDOW_ID = 9002;
const WINDOW_ID = 9001;
const fixture = JSON.parse(await fs.readFile(new URL("./fixtures/textedit-outline.json", import.meta.url), "utf8"));
const rowFixture = JSON.parse(await fs.readFile(new URL("./fixtures/finder-outline.json", import.meta.url), "utf8"));

function toWireNode(node) {
	return { ...node, ref: node.wireRef, wireRef: undefined, children: node.children.map(toWireNode) };
}

const outline = toWireNode(fixture.root);
const rowOutline = toWireNode(rowFixture.root);
const values = new Map();
const actRequests = [];

function withValues(node) {
	return { ...node, value: values.get(node.ref) ?? node.value, children: node.children.map(withValues) };
}

let lookCounter = 0;

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
		case "listApps": return { apps: [APP, EMPTY_APP, DESKTOP_APP, ROWS_APP] };
		case "listRoots": return {
			roots: request.pid === EMPTY_APP.pid ? [] : request.pid === ROWS_APP.pid ? [{
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
			}],
		};
		case "getFrontmost": return { ...APP, windowId: WINDOW_ID, windowTitle: "未命名2" };
		case "look": return {
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
			outline: request.windowId === ROWS_WINDOW_ID ? rowOutline : withValues(outline),
			timings: {},
		};
		case "act": {
			actRequests.push(request);
			if (request.action === "setText") values.set(request.target.ref, request.params.text);
			return {
				outcome: "worked",
				performed: { delivery: "ax" },
				verification: { source: "ax", field: "value", from: "0", to: "1" },
			};
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
			socket.write(`${JSON.stringify({ id: request.id, ok: true, result: helperResult(request) })}\n`);
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
	assert.match(text.stdout.split("\n")[0], /^@r\d+ Fixture — 未命名2 · state [0-9a-f-]{36} · 47 nodes, \d+ shown$/, `observe-ui header drifted: ${text.stdout.split("\n")[0]}`);

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
	assert.equal(waited.stateId.length, 36, "wait-for did not return a successor state");

	const timedOut = await runCli(["wait-for", "--state", acted.stateId, "--text", "__never__", "--timeout", "200", "--json"], { env });
	assert.equal(timedOut.code, 8, `wait-for timeout exited ${timedOut.code}`);
	assert.equal(timedOut.stdout, "", "wait-for timeout wrote to stdout");
	assert.match(timedOut.stderr, /^error action_timeout: /m, "wait-for timeout is not a stable action_timeout");

	const actedText = await runCli(["act-ui", "--state", acted.stateId, "-"], {
		env,
		input: `${JSON.stringify([{ action: "press", ref: editorRef }])}\n`,
	});
	assert.equal(actedText.code, 0, `act-ui text view exited ${actedText.code}: ${actedText.stderr}`);
	assert.match(actedText.stdout.split("\n")[0], / · worked via ax · value 0→1$/, `act-ui does not show why the helper called it worked: ${actedText.stdout.split("\n")[0]}`);

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
