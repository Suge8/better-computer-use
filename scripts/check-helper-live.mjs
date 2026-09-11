#!/usr/bin/env node
// The installed helper still honours the contract the runtime depends on: one look per
// moment, rects inside the captured image, stable root and element identities, and an
// outline that projects into the agent vocabulary.
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { HELPER_PROTOCOL_VERSION } from "../src/macos/helper.ts";
import { graftScopedOutline, nodeByRef, parseLookResponse } from "../src/outline.ts";
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

async function pidForWindow(socketPath, windowId) {
	const apps = await call(socketPath, { id: "inv-apps", cmd: "listApps" });
	for (const app of Array.isArray(apps) ? apps : []) {
		const windows = ((await call(socketPath, { id: `inv-roots-${app.pid}`, cmd: "listRoots", pid: app.pid }).catch(() => ({ roots: [] }))).roots) ?? [];
		const match = Array.isArray(windows) ? windows.find((window) => window?.windowId === windowId) : undefined;
		if (match) return { pid: app.pid, appName: app.appName, title: match.title ?? match.windowTitle };
	}
	return undefined;
}

async function liveChecks() {
	if (process.env.BCU_LIVE !== "1") {
		console.log("SKIP live helper checks (set BCU_LIVE=1)");
		return;
	}
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
		const explicitRootRef = process.env.BCU_LIVE_ROOT_REF || undefined;
		let windows = [];
		try {
			const frontmost = await call(socketPath, { id: "inv-frontmost", cmd: "getFrontmost" });
			windows = ((await call(socketPath, { id: "inv-roots", cmd: "listRoots", pid: frontmost.pid })).roots) ?? [];
			check("listRoots pairing", () => {
				assert(Array.isArray(windows), "listRoots did not return an array");
				for (const window of windows) {
					assert(["exact", "high", "low"].includes(window?.metadata?.pairing?.confidence), `invalid pairing ${JSON.stringify(window?.metadata?.pairing)}`);
				}
			});
		} catch (error) {
			if (!explicitRootRef) throw error;
			console.log(`SKIP listRoots pairing (${error.message}; explicit BCU_LIVE_ROOT_REF=${explicitRootRef})`);
		}
		let target = explicitRootRef
			? { rootRef: explicitRootRef, title: "BCU_LIVE_ROOT_REF", appName: "explicit target" }
			: Array.isArray(windows) ? windows.find((window) => window?.rootRef && Number.isFinite(window?.windowId)) : undefined;
		if (!target) {
			console.log("SKIP look (no capturable frontmost window; Accessibility may be missing)");
			return;
		}
		const look = await call(socketPath, { id: "inv-look", cmd: "look", rootRef: target.rootRef, windowId: target.windowId, readText: "always" }, 20000);
		if (explicitRootRef) {
			target = { ...target, ...look.window, title: look.window?.title ?? target.title };
		}
		const pidInfo = await pidForWindow(socketPath, target.windowId);
		if (pidInfo) {
			target = { ...target, ...pidInfo, appName: pidInfo.appName ?? target.appName, title: pidInfo.title ?? target.title };
		}
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
		const fullOutline = parseLookResponse(look).parsedOutline;
		const truncated = fullOutline?.nodes.find((node) => node.truncated && node.wireRef);
		if (!fullOutline || !truncated) {
			console.log(`SKIP scoped graft (no truncated node in ${windowLabel(target)})`);
		} else {
			const beforeRefs = new Map(fullOutline.nodes.map((node) => [node.ref, node.wireRef]));
			const beforeMax = Math.max(...fullOutline.nodes.map((node) => Number(/^@e(\d+)$/.exec(node.ref)?.[1] ?? 0)));
			const state = { stateId: "full-state", capture: { width: look.image.width, height: look.image.height } };
			const scopedLook = await call(socketPath, { id: "inv-look-scope", cmd: "look", windowId: target.windowId, readText: "auto", scopeRef: truncated.wireRef, maxDimension: 1 }, 20000);
			check("scoped graft preserves full state", () => {
				const scopedOutline = parseLookResponse(scopedLook).parsedOutline;
				assert(scopedOutline, "scoped look did not parse");
				graftScopedOutline(fullOutline, truncated.ref, scopedOutline);
				for (const [ref, wireRef] of beforeRefs) {
					const node = nodeByRef(fullOutline, ref);
					assert(node, `pre-existing ref disappeared: ${ref}`);
					assert(node.wireRef === wireRef, `pre-existing ref changed elementRef: ${ref}`);
				}
				assert(state.stateId === "full-state" && state.capture.width === look.image.width && state.capture.height === look.image.height, "state/capture sentinel changed");
				const afterMax = Math.max(...fullOutline.nodes.map((node) => Number(/^@e(\d+)$/.exec(node.ref)?.[1] ?? 0)));
				assert(afterMax >= beforeMax, "ref counter moved backwards");
				for (const node of fullOutline.nodes) {
					const number = Number(/^@e(\d+)$/.exec(node.ref)?.[1] ?? 0);
					if (!beforeRefs.has(node.ref)) assert(number > beforeMax, `new ref did not continue numbering: ${node.ref}`);
				}
			});
		}
	} catch (error) {
		results.push(["live", false]);
		process.exitCode = 1;
		console.error(`FAIL live helper ${error.message}`);
	}
}

await liveChecks();
if (results.some(([, ok]) => !ok)) process.exit(1);
