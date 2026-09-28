#!/usr/bin/env node
// Web content is driven in the background. A dedicated Google Chrome renders a local page;
// every cell hands the front to a stand-in for the user's app, runs one public `bcu act-ui`,
// and then asks the page itself over the DevTools protocol whether the effect happened.
// Each cell holds bcu to the background promise: the DOM changed, the user's app is still
// in front and never lost its key window or activation, the real pointer did not move,
// and the action was not delivered as foreground HID input.
// Elements that show no trace of a press are pressed exactly once and reported as a
// failure that tells the caller to look before retrying, never replayed on a higher rung.
import assert from "node:assert/strict";
import { execFile as execFileCallback, spawn } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { brokerEnvironment, buildBundle, killProcess, launchKeyHolder, makeTemporaryRoot, runCli, withTimeout } from "./lib/harness.mjs";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP web background matrix (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The web background matrix requires macOS.");

const execFile = promisify(execFileCallback);
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const TYPED = "bcu typed 42";
const SET = "bcu set 7";

const FIXTURE_HTML = `<!doctype html>
<meta charset="utf-8">
<title>bcu web fixture</title>
<body>
<button id="count" data-n="0" onclick="this.dataset.n = Number(this.dataset.n) + 1; this.textContent = 'Clicked ' + this.dataset.n">Count clicks</button>
<p><input id="set" aria-label="Set field"></p>
<p><input id="type" aria-label="Type field"></p>
<p><input id="keys" aria-label="Key log" onkeydown="window.keydowns.push(event.key)"></p>
<div id="down" role="button" aria-label="Down only" data-n="0" onmousedown="this.dataset.n = Number(this.dataset.n) + 1">Down only</div>
<div id="clickonly" role="button" aria-label="Click only" data-n="0" onclick="this.dataset.n = Number(this.dataset.n) + 1">Click only</div>
<div id="scroller" role="region" aria-label="Scroll area" style="height: 80px; overflow: auto"><div style="height: 2000px">Scroll content</div></div>
<script>
window.keydowns = [];
document.title = "bcu web fixture " + new URLSearchParams(location.search).get("w");
</script>
</body>`;

const root = await makeTemporaryRoot("web-background");
const env = brokerEnvironment(path.join(root, "broker.sock"), 30_000);
let chrome;
let holder;

/** Front application and real pointer, read by a process that is not bcu. */
async function desktop() {
	const { stdout } = await execFile("osascript", ["-l", "JavaScript", "-e", [
		"ObjC.import('AppKit')",
		"const m = $.NSEvent.mouseLocation",
		"JSON.stringify({ front: $.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier, x: m.x, y: m.y })",
	].join(";")]);
	return JSON.parse(stdout);
}

/** Sets `chrome` as soon as the process exists, so cleanup reaches a launch that fails halfway. */
async function launchChrome(profile) {
	await fs.mkdir(profile);
	const watcher = fs.watch(profile);
	const child = spawn(CHROME, [
		`--user-data-dir=${profile}`,
		"--remote-debugging-port=0",
		"--no-first-run",
		"--no-default-browser-check",
		"--new-window",
		pageUrl("A"),
	], { stdio: "ignore" });
	const exited = once(child, "exit");
	chrome = { child, exited };
	const portFile = path.join(profile, "DevToolsActivePort");
	const ready = (async () => {
		for (;;) {
			const text = await fs.readFile(portFile, "utf8").catch(() => "");
			const [port, browserPath] = text.split("\n");
			if (port && browserPath) return { port: Number(port), browserPath };
			await watcher.next();
		}
	})();
	try {
		const devtools = await withTimeout(Promise.race([
			ready,
			exited.then(([code]) => { throw new Error(`Chrome exited during launch (${code})`); }),
		]), "Chrome DevTools to listen", 20_000);
		Object.assign(chrome, devtools);
	} finally {
		await watcher.return?.();
	}
}

function pageUrl(name) {
	return `file://${path.join(root, "fixture.html")}?w=${name}`;
}

async function stopChrome() {
	if (!chrome || !killProcess(chrome.child.pid, "SIGTERM")) return;
	try {
		await withTimeout(chrome.exited, "the fixture Chrome to exit", 5_000);
	} catch {
		if (killProcess(chrome.child.pid, "SIGKILL")) await chrome.exited;
	}
}

/** One DevTools session; `send` resolves with the command result. */
async function devtoolsSession(url) {
	const socket = new WebSocket(url);
	await new Promise((resolve, reject) => {
		socket.addEventListener("open", resolve, { once: true });
		socket.addEventListener("error", () => reject(new Error(`DevTools socket ${url} failed`)), { once: true });
	});
	let nextId = 0;
	const pending = new Map();
	socket.addEventListener("message", (event) => {
		const message = JSON.parse(event.data);
		const waiter = pending.get(message.id);
		if (!waiter) return;
		pending.delete(message.id);
		if (message.error) waiter.reject(new Error(message.error.message));
		else waiter.resolve(message.result);
	});
	return {
		send(method, params = {}) {
			const id = ++nextId;
			socket.send(JSON.stringify({ id, method, params }));
			return withTimeout(new Promise((resolve, reject) => pending.set(id, { resolve, reject })), `DevTools ${method}`, 10_000);
		},
		close: () => socket.close(),
	};
}

async function pageSession(name) {
	const response = await fetch(`http://127.0.0.1:${chrome.port}/json/list`);
	const page = (await response.json()).find((target) => target.type === "page" && target.url === pageUrl(name));
	assert(page, `Chrome has no page for window ${name}`);
	return await devtoolsSession(page.webSocketDebuggerUrl);
}

/** The DOM's own account of the fixture, independent of anything bcu reads. */
async function dom(session) {
	const result = await session.send("Runtime.evaluate", {
		expression: `({ count: Number(document.getElementById("count").dataset.n), down: Number(document.getElementById("down").dataset.n), clickOnly: Number(document.getElementById("clickonly").dataset.n), scrollTop: document.getElementById("scroller").scrollTop, set: document.getElementById("set").value, type: document.getElementById("type").value, keys: window.keydowns.slice(), ready: document.readyState })`,
		returnByValue: true,
	});
	return result.result.value;
}

async function bcu(args, input) {
	const result = await runCli([...args, "--json"], { input, env });
	if (result.code !== 0) throw new Error(`bcu ${args[0]} exited ${result.code}: ${result.stderr.trim()}`);
	return JSON.parse(result.stdout);
}

/** A press with no observable trace must fail honestly and say the press may already have landed. */
async function unprovenPress(stateId, ref) {
	const result = await runCli(["act-ui", "--state", stateId, "-", "--json"], { input: `${JSON.stringify([{ action: "press", ref }])}\n`, env });
	const recovery = result.stderr.match(/^recovery: (.+)$/m)?.[1] ?? "";
	const problems = [
		result.code === 9 ? "" : `exit ${result.code}, want 9`,
		result.stdout === "" ? "" : "wrote a success to stdout",
		/^error action_failed: /m.test(result.stderr) ? "" : `stderr ${JSON.stringify(result.stderr)}`,
		/may already have taken effect/i.test(recovery) && /observe/i.test(recovery) ? "" : `recovery ${JSON.stringify(recovery)} does not say the action may already have taken effect and to observe first`,
	].filter(Boolean);
	return { delivery: undefined, problems };
}

/** Chrome builds its accessibility tree once an assistive client asks, so wait for the named control. */
async function observeWindow(name, fieldName) {
	const roots = await bcu(["find-roots", "--pid", String(chrome.child.pid), "--kind", "window"]);
	const window = roots.roots.find((candidate) => candidate.title.includes(`bcu web fixture ${name}`));
	assert(window, `bcu found no window for fixture ${name}: ${roots.roots.map((candidate) => candidate.title).join(", ")}`);
	const first = await bcu(["observe-ui", "--root", window.ref]);
	await bcu(["wait-for", "--state", first.stateId, "--text", fieldName, "--timeout", "10000"]);
	return await bcu(["observe-ui", "--root", window.ref]);
}

async function refFor(stateId, text, role) {
	const found = await bcu(["search-ui", "--state", stateId, "--text", text, "--role", role, "--limit", "1"]);
	assert(found.matches[0], `no ${role} named ${text} in state ${stateId}`);
	return found.matches[0].ref;
}

const cells = [];

/** Runs one cell and records every background promise it broke instead of stopping at the first. */
async function cell(name, run) {
	const failures = [];
	try {
		const logged = (await holder.takeFront()).length;
		const before = await desktop();
		assert.equal(before.front, holder.pid, "the key holder did not take the front before the cell");
		const { result, effect } = await run();
		const after = await desktop();
		if (!effect.ok) failures.push(`DOM effect missing: ${effect.detail}`);
		if (after.front !== before.front) failures.push(`front app changed ${before.front} → ${after.front}`);
		const lost = (await holder.logged()).slice(logged);
		if (lost.length) failures.push(`the user's front app lost its key window or activation: ${lost.join(", ")}`);
		if (after.x !== before.x || after.y !== before.y) failures.push(`real pointer moved (${before.x},${before.y}) → (${after.x},${after.y})`);
		if (result.delivery === "hid") failures.push("delivered as foreground HID input");
	} catch (error) {
		failures.push(error.message);
	}
	cells.push({ name, failures });
	console.log(`${failures.length ? "FAIL" : "PASS"} ${name}${failures.map((failure) => `\n  - ${failure}`).join("")}`);
}

async function act(stateId, actions) {
	return await bcu(["act-ui", "--state", stateId, "-"], `${JSON.stringify(actions)}\n`);
}

try {
	await buildBundle();
	holder = await launchKeyHolder(root);
	await fs.writeFile(path.join(root, "fixture.html"), FIXTURE_HTML);
	await launchChrome(path.join(root, "profile"));
	const pageA = await pageSession("A");
	const observed = await observeWindow("A", "Key log");
	const refs = {
		button: await refFor(observed.stateId, "Count clicks", "button"),
		set: await refFor(observed.stateId, "Set field", "textfield"),
		type: await refFor(observed.stateId, "Type field", "textfield"),
		keys: await refFor(observed.stateId, "Key log", "textfield"),
	};

	await cell("web button press", async () => {
		const result = await act(observed.stateId, [{ action: "press", ref: refs.button }]);
		const state = await dom(pageA);
		return { result, effect: { ok: state.count === 1, detail: `count ${state.count}, want exactly 1` } };
	});
	await cell("web input setText", async () => {
		const state = await observeWindow("A", "Set field");
		const result = await act(state.stateId, [{ action: "setText", ref: await refFor(state.stateId, "Set field", "textfield"), text: SET }]);
		const now = await dom(pageA);
		return { result, effect: { ok: now.set === SET, detail: `value ${JSON.stringify(now.set)}` } };
	});
	await cell("web input typeText", async () => {
		const state = await observeWindow("A", "Type field");
		const result = await act(state.stateId, [{ action: "typeText", ref: await refFor(state.stateId, "Type field", "textfield"), text: TYPED }]);
		const now = await dom(pageA);
		return { result, effect: { ok: now.type === TYPED, detail: `value ${JSON.stringify(now.type)}` } };
	});
	await cell("web keypress Enter", async () => {
		const state = await observeWindow("A", "Key log");
		const result = await act(state.stateId, [{ action: "keypress", ref: await refFor(state.stateId, "Key log", "textfield"), keys: ["Enter"] }]);
		const now = await dom(pageA);
		return { result, effect: { ok: now.keys.includes("Enter"), detail: `keydowns ${JSON.stringify(now.keys)}` } };
	});

	for (const [name, field] of [["Down only", "down"], ["Click only", "clickOnly"]]) {
		await cell(`press a non-focusable element listening only to ${field === "down" ? "mousedown" : "click"}`, async () => {
			const state = await observeWindow("A", name);
			const result = await unprovenPress(state.stateId, await refFor(state.stateId, name, "button"));
			const now = await dom(pageA);
			const problems = [...result.problems, now[field] === 1 ? "" : `${field} fired ${now[field]} times, want exactly 1`].filter(Boolean);
			return { result, effect: { ok: problems.length === 0, detail: problems.join("; ") } };
		});
	}
	await cell("coordinate click on a web button", async () => {
		const state = await bcu(["observe-ui", "--root", observed.root.ref, "--image", "always"]);
		const { node } = await bcu(["inspect-ui", "--state", state.stateId, "--ref", await refFor(state.stateId, "Clicked", "button")]);
		const before = await dom(pageA);
		const result = await act(state.stateId, [{ action: "click", x: node.rect.x + node.rect.w / 2, y: node.rect.y + node.rect.h / 2 }]);
		const now = await dom(pageA);
		const ok = now.count === before.count + 1 && result.delivery === "pid";
		return { result, effect: { ok, detail: `count ${before.count} → ${now.count}, want +1; delivery ${result.delivery}, want pid` } };
	});
	await cell("scroll a web scroll area", async () => {
		const state = await observeWindow("A", "Scroll area");
		const found = await bcu(["search-ui", "--state", state.stateId, "--text", "Scroll area", "--action", "scroll", "--limit", "1"]);
		if (!found.matches[0]) throw new Error("the scroll area exposes no scroll capability");
		const result = await act(state.stateId, [{ action: "scroll", ref: found.matches[0].ref, scrollY: 200 }]);
		const now = await dom(pageA);
		return { result, effect: { ok: now.scrollTop > 0, detail: `scrollTop ${now.scrollTop}` } };
	});

	// A second window of the same process becomes Chrome's key window; typing into the
	// first one must land there and nowhere else.
	const browser = await devtoolsSession(`ws://127.0.0.1:${chrome.port}${chrome.browserPath}`);
	await browser.send("Target.createTarget", { url: pageUrl("B"), newWindow: true });
	browser.close();
	const pageB = await pageSession("B");
	await observeWindow("B", "Key log");
	await cell("typeText into the non-key window of two", async () => {
		const beforeA = await dom(pageA);
		const state = await observeWindow("A", "Type field");
		const result = await act(state.stateId, [{ action: "typeText", ref: await refFor(state.stateId, "Type field", "textfield"), text: TYPED }]);
		const [nowA, nowB] = [await dom(pageA), await dom(pageB)];
		const stray = nowB.set || nowB.type || nowB.keys.length ? ` window B changed ${JSON.stringify(nowB)}` : "";
		return { result, effect: { ok: nowA.type === beforeA.type + TYPED && !stray, detail: `window A value ${JSON.stringify(nowA.type)}${stray}` } };
	});
	pageA.close();
	pageB.close();
} finally {
	await stopChrome();
	if (holder && killProcess(holder.pid, "SIGTERM")) await withTimeout(holder.exited, "the key holder to exit", 5_000).catch(() => killProcess(holder.pid));
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(root, { recursive: true, force: true });
}

const failed = cells.filter((entry) => entry.failures.length);
console.log(`${cells.length - failed.length}/${cells.length} web background cells passed`);
if (failed.length || cells.length === 0) process.exit(1);
