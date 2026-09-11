#!/usr/bin/env node
// The installed helper still honours the contract the runtime depends on: one look per
// moment, rects inside the captured image, stable root and element identities, and an
// outline that projects into the agent vocabulary. The subject is a TextEdit window this
// gate opens itself, so the verdict never depends on what the desktop happens to show.
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { launchTextEdit, makeTemporaryRoot, monitorProcess, stopTextEdit, waitForAxWindow } from "./lib/harness.mjs";
import { HELPER_PROTOCOL_VERSION } from "../src/macos/helper.ts";
import { parseLookResponse } from "../src/outline.ts";
import { CAPABILITIES, project, renderObservation } from "../src/projection.ts";

const results = [];

function check(name, fn) {
	try {
		fn();
		results.push([name, true]);
		console.log(`PASS ${name}`);
	} catch (error) {
		results.push([name, false]);
		process.exitCode = 1;
		console.error(`FAIL ${name}: ${error.message}`);
	}
}

function assert(condition, message) {
	if (!condition) throw new Error(message);
}

function call(socketPath, payload, timeoutMs = 10000) {
	return new Promise((resolve, reject) => {
		const socket = net.createConnection(socketPath);
		let buffer = "";
		const timer = setTimeout(() => {
			socket.destroy();
			reject(new Error(`timeout calling ${payload.cmd}`));
		}, timeoutMs);
		socket.setEncoding("utf8");
		socket.on("connect", () => socket.write(`${JSON.stringify(payload)}\n`));
		socket.on("data", (chunk) => {
			buffer += chunk;
			const newline = buffer.indexOf("\n");
			if (newline < 0) return;
			clearTimeout(timer);
			socket.end();
			const parsed = JSON.parse(buffer.slice(0, newline));
			if (!parsed.ok) reject(new Error(parsed.error?.message ?? `${payload.cmd} failed`));
			else resolve(parsed.result);
		});
		socket.on("error", (error) => {
			clearTimeout(timer);
			reject(error);
		});
	});
}

function abandon(socketPath, payload) {
	return new Promise((resolve, reject) => {
		const socket = net.createConnection(socketPath);
		socket.on("connect", () => {
			socket.write(`${JSON.stringify(payload)}\n`, () => {
				socket.destroy();
				resolve();
			});
		});
		socket.on("error", reject);
	});
}

async function waitForCompletedRequest(socketPath, requestId, timeoutMs = 10000) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		const diagnostics = await call(socketPath, { id: `inv-completion-${Date.now()}`, cmd: "diagnostics" });
		if (diagnostics.recentCompletedRequestIds?.includes(requestId)) return diagnostics;
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
	throw new Error(`request ${requestId} did not complete within ${timeoutMs}ms`);
}

function callEnvelope(socketPath, payload, timeoutMs = 10000) {
	return new Promise((resolve, reject) => {
		const socket = net.createConnection(socketPath);
		let buffer = "";
		const timer = setTimeout(() => {
			socket.destroy();
			reject(new Error(`timeout calling ${payload.cmd}`));
		}, timeoutMs);
		socket.setEncoding("utf8");
		socket.on("connect", () => socket.write(`${JSON.stringify(payload)}\n`));
		socket.on("data", (chunk) => {
			buffer += chunk;
			const newline = buffer.indexOf("\n");
			if (newline < 0) return;
			clearTimeout(timer);
			socket.end();
			resolve(JSON.parse(buffer.slice(0, newline)));
		});
		socket.on("error", (error) => {
			clearTimeout(timer);
			reject(error);
		});
	});
}

function walk(node, visit) {
	visit(node);
	for (const child of Array.isArray(node?.children) ? node.children : []) walk(child, visit);
}

function windowLabel(window) {
	if (!window) return "unknown window";
	return `${window.appName ?? window.app ?? "unknown app"} — ${window.title ?? window.windowTitle ?? "(untitled)"} (${window.windowId ?? "no windowId"})`;
}

/** Several lines of plain text, so the captured image has something for OCR to find. */
const FIXTURE_TEXT = "bcu live helper fixture\nsecond line of fixture text\nthird line of fixture text\n";

async function liveChecks() {
	if (process.env.BCU_LIVE !== "1") {
		console.log("SKIP live helper checks (set BCU_LIVE=1)");
		return;
	}
	const fixtureDirectory = await makeTemporaryRoot("helper-live");
	const fixtureTitle = `bcu-helper-live-${randomUUID()}`;
	let fixturePid;
	let fixtureMonitor;
	try {
		const socketPath = process.env.BCU_SOCKET_PATH ?? path.join(os.homedir(), "Library/Caches/bcu/bridge.sock");
		const diagnostics = await call(socketPath, { id: "inv-diagnostics", cmd: "diagnostics" });
		check("diagnostics current protocol", () => assert(diagnostics.protocolVersion === HELPER_PROTOCOL_VERSION, `protocolVersion=${diagnostics.protocolVersion}`));
		const broadDiscoveryStarted = Date.now();
		const broadRoots = await call(socketPath, { id: "inv-broad-roots", cmd: "listRoots" }, 10000);
		const broadDiscoveryMs = Date.now() - broadDiscoveryStarted;
		const diagnosticsAfterBroadDiscovery = await call(socketPath, { id: "inv-diagnostics-after-broad-roots", cmd: "diagnostics" });
		check("broad root discovery is bounded and keeps helper alive", () => {
			assert(Array.isArray(broadRoots?.roots), "broad listRoots did not return roots");
			assert(broadDiscoveryMs < 10000, `broad listRoots took ${broadDiscoveryMs}ms`);
			assert(diagnosticsAfterBroadDiscovery.protocolVersion === HELPER_PROTOCOL_VERSION, "helper did not survive broad listRoots");
		});
		const abandonedRequestId = `inv-abandoned-roots-${process.pid}-${Date.now()}`;
		await abandon(socketPath, { id: abandonedRequestId, cmd: "listRoots" });
		const diagnosticsAfterAbandon = await waitForCompletedRequest(socketPath, abandonedRequestId);
		check("abandoned root discovery keeps helper alive", () => {
			assert(diagnosticsAfterAbandon.protocolVersion === HELPER_PROTOCOL_VERSION, "helper died after writing to an abandoned root-discovery socket");
		});
		await fs.writeFile(path.join(fixtureDirectory, `${fixtureTitle}.txt`), FIXTURE_TEXT);
		fixturePid = await launchTextEdit(path.join(fixtureDirectory, `${fixtureTitle}.txt`));
		fixtureMonitor = await monitorProcess(fixturePid);
		await waitForAxWindow(fixturePid, fixtureMonitor.exited, fixtureTitle);
		const windows = ((await call(socketPath, { id: "inv-roots", cmd: "listRoots", pid: fixturePid })).roots) ?? [];
		check("listRoots pairing", () => {
			assert(Array.isArray(windows), "listRoots did not return an array");
			for (const window of windows) {
				// The menu bar is the one root with no window of its own to pair with.
				if (window?.kind === "menubar") {
					assert(window.metadata?.pairing === undefined, `the menu bar claimed a window pairing: ${JSON.stringify(window.metadata)}`);
					continue;
				}
				assert(["exact", "high", "low"].includes(window?.metadata?.pairing?.confidence), `invalid pairing ${JSON.stringify(window?.metadata?.pairing)}`);
			}
		});
		// TextEdit restores earlier documents into a fresh instance; the fixture window is the
		// one named after the fixture.
		const target = {
			...windows.find((window) => (window?.title ?? "").startsWith(fixtureTitle) && window?.rootRef && Number.isFinite(window?.windowId)),
			pid: fixturePid,
			appName: "TextEdit",
		};
		assert(target.rootRef, `the fixture window ${fixtureTitle} is not a capturable root: ${JSON.stringify(windows.map((window) => window?.title))}`);
		const look = await call(socketPath, { id: "inv-look", cmd: "look", rootRef: target.rootRef, windowId: target.windowId, readText: "always" }, 20000);
		check("look one moment", () => {
			assert(typeof look.capturedAt === "number", "missing capturedAt");
			assert(look.image && look.outline, "missing image or outline");
		});
		check("rects within image", () => {
			walk(look.outline, (node) => {
				const rect = node?.rect;
				if (!rect) return;
				assert(rect.x >= 0 && rect.y >= 0 && rect.x + rect.w <= look.image.width + 0.01 && rect.y + rect.h <= look.image.height + 0.01, `rect out of bounds ${JSON.stringify(rect)}`);
			});
		});
		check("text annotations", () => {
			let found = false;
			walk(look.outline, (node) => {
				if (Array.isArray(node?.text) && node.text.length) found = true;
			});
			assert(found, "no text annotations");
		});
		check("window pairing", () => {
			assert(look.window?.metadata?.pairing, "missing window.metadata.pairing");
		});
		assert(Number.isFinite(target.pid), `could not resolve pid for ${windowLabel(target)}`);
		const centerX = Math.floor(look.image.width / 2);
		const centerY = Math.floor(look.image.height / 2);
		const hit = await call(socketPath, { id: "inv-hit-test", cmd: "hitTest", lookId: look.lookId, windowId: target.windowId, x: centerX, y: centerY }, 10000);
		const staleRef = await callEnvelope(socketPath, { id: "inv-act-stale-ref", cmd: "act", lookId: look.lookId, pid: target.pid, target: { ref: "bogus-ref-for-invariant" }, action: "press", params: {} }, 10000);
		const staleLook = await callEnvelope(socketPath, { id: "inv-act-stale-look", cmd: "act", lookId: "bogus-look-for-invariant", pid: target.pid, target: { x: centerX, y: centerY }, action: "moveMouse", params: {} }, 10000);
		check("hitTest and stale act errors", () => {
			assert(Number.isFinite(target.pid), `could not resolve pid for ${windowLabel(target)}`);
			assert(hit && typeof hit.role === "string", `hitTest did not return a node: ${JSON.stringify(hit)}`);
			assert(staleRef.ok === false && staleRef.error?.code === "stale_ref", `bogus ref did not return stale_ref: ${JSON.stringify(staleRef)}`);
			assert(staleLook.ok === false && staleLook.error?.code === "stale_look", `bogus look did not return stale_look: ${JSON.stringify(staleLook)}`);
		});
		check("projection stays inside the agent vocabulary", () => {
			const parsed = parseLookResponse(look).parsedOutline;
			assert(parsed, "parseLookResponse did not return parsed outline");
			const projection = project(parsed);
			assert(projection.nodes.length > 0, "projection produced no nodes");
			assert(projection.total === parsed.nodes.length, `projection total ${projection.total} != outline ${parsed.nodes.length}`);
			for (const node of projection.nodes) {
				assert(!/^ax/i.test(node.role), `projected role kept its AX prefix: ${node.role}`);
				for (const capability of node.caps) assert(CAPABILITIES.includes(capability), `projected capability outside the vocabulary: ${capability}`);
			}
			const text = renderObservation({ stateId: "live", root: { ref: "@r1", app: "live", title: windowLabel(target) }, nodes: projection.nodes, shown: projection.shown, total: projection.total });
			assert(!/\bAX[A-Z]/.test(text), `live view leaks raw accessibility names:\n${text}`);
			const focused = parsed.nodes.filter((node) => node.focused && node.canFocus);
			for (const node of focused) {
				const visible = projection.nodes.some((candidate) => candidate.ref === node.ref) || projection.nodes.some((candidate) => candidate.hidden);
				assert(visible, `focused ref ${node.ref} was neither rendered nor folded`);
			}
		});
	} catch (error) {
		results.push(["live", false]);
		process.exitCode = 1;
		console.error(`FAIL live helper ${error.message}`);
	} finally {
		if (fixturePid) await stopTextEdit(fixturePid, fixtureMonitor);
		await fs.rm(fixtureDirectory, { recursive: true, force: true });
	}
}

await liveChecks();
if (results.some(([, ok]) => !ok)) process.exit(1);
