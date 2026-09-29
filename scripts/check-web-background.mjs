#!/usr/bin/env node
// Web content is driven in the background. A dedicated Google Chrome renders a local page;
// every cell hands the front to a stand-in for the user's app, runs one public `bcu act-ui`,
// and then asks the page itself over the DevTools protocol whether the effect happened.
// Each cell holds bcu to the background promise: the DOM changed, the user's app is still
// in front and never lost its key window or activation, the real pointer did not move,
// and the action was not delivered as foreground HID input.
// Elements that show no trace of a press are pressed exactly once and reported as an
// unverified success, never replayed on a higher rung. A drag over an area that follows
// pointer events reaches the page as one pointerdown-to-pointerup gesture. Scroll amounts
// share one rule on both axes: positive scrollY scrolls down, positive scrollX right.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { launchChrome, pageSession, devtoolsSession, stopChrome } from "./lib/chrome.mjs";
import { residentEnvironment, desktop, killProcess, launchKeyHolder, makeTemporaryRoot, runCli, withTimeout } from "./lib/harness.mjs";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP web background matrix (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The web background matrix requires macOS.");

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
<div id="wide" role="region" aria-label="Wide area" style="width: 200px; overflow: auto"><div style="width: 4000px">Wide content</div></div>
<div id="drag" role="region" aria-label="Drag area" style="width: 320px; height: 60px; background: #ddd; touch-action: none">Drag area</div>
<script>
window.keydowns = [];
window.dragged = [];
const dragArea = document.getElementById("drag");
let dragFrom;
dragArea.addEventListener("pointerdown", (event) => { dragFrom = event.clientX; dragArea.setPointerCapture(event.pointerId); });
dragArea.addEventListener("pointerup", (event) => { if (dragFrom !== undefined) window.dragged.push(Math.round(event.clientX - dragFrom)); dragFrom = undefined; });
document.title = "bcu web fixture " + new URLSearchParams(location.search).get("w");
</script>
</body>`;

const root = await makeTemporaryRoot("web-background");
const env = residentEnvironment(path.join(root, "resident.sock"), 30_000);
let chrome;
let holder;

function pageUrl(name) {
	return `file://${path.join(root, "fixture.html")}?w=${name}`;
}

/** The DOM's own account of the fixture, independent of anything bcu reads. */
async function dom(session) {
	const result = await session.send("Runtime.evaluate", {
		expression: `({ count: Number(document.getElementById("count").dataset.n), down: Number(document.getElementById("down").dataset.n), clickOnly: Number(document.getElementById("clickonly").dataset.n), scrollTop: document.getElementById("scroller").scrollTop, scrollLeft: document.getElementById("wide").scrollLeft, set: document.getElementById("set").value, type: document.getElementById("type").value, keys: window.keydowns.slice(), dragged: window.dragged.slice(), ready: document.readyState })`,
		returnByValue: true,
	});
	return result.result.value;
}

async function bcu(args, input) {
	const result = await runCli([...args, "--json"], { input, env });
	if (result.code !== 0) throw new Error(`bcu ${args[0]} exited ${result.code}: ${result.stderr.trim()}`);
	return JSON.parse(result.stdout);
}

/** A press with no observable trace succeeds as unverified: it claims neither worked nor failed. */
async function unprovenPress(stateId, ref) {
	const result = await runCli(["act-ui", "--state", stateId, "-", "--json"], { input: `${JSON.stringify([{ action: "press", ref }])}\n`, env });
	const outcome = result.code === 0 ? JSON.parse(result.stdout) : undefined;
	const problems = [
		result.code === 0 ? "" : `exit ${result.code}, want 0: ${result.stderr.trim()}`,
		outcome && outcome.outcome !== "unknown" ? `outcome ${outcome.outcome}, want unknown` : "",
	].filter(Boolean);
	return { delivery: outcome?.delivery, problems };
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
	holder = await launchKeyHolder(root);
	await fs.writeFile(path.join(root, "fixture.html"), FIXTURE_HTML);
	await launchChrome(path.join(root, "profile"), pageUrl("A"), (spawned) => { chrome = spawned; });
	const pageA = await pageSession(chrome, pageUrl("A"));
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
		const result = await act(state.stateId, [{ action: "scroll", ref: found.matches[0].ref, scrollY: 5 }]);
		const now = await dom(pageA);
		return { result, effect: { ok: now.scrollTop > 0, detail: `scrollTop ${now.scrollTop}` } };
	});
	await cell("scroll a web area to the right", async () => {
		const state = await observeWindow("A", "Wide area");
		const found = await bcu(["search-ui", "--state", state.stateId, "--text", "Wide area", "--action", "scroll", "--limit", "1"]);
		if (!found.matches[0]) throw new Error("the wide area exposes no scroll capability");
		const result = await act(state.stateId, [{ action: "scroll", ref: found.matches[0].ref, scrollX: 5 }]);
		const now = await dom(pageA);
		return { result, effect: { ok: now.scrollLeft > 0, detail: `scrollLeft ${now.scrollLeft}, want it moved right` } };
	});

	await cell("drag across a pointer-event area", async () => {
		const state = await bcu(["observe-ui", "--root", observed.root.ref, "--image", "always"]);
		const found = await bcu(["search-ui", "--state", state.stateId, "--text", "Drag area", "--limit", "1"]);
		assert(found.matches[0], "the page shows no Drag area");
		const { node } = await bcu(["inspect-ui", "--state", state.stateId, "--ref", found.matches[0].ref]);
		const y = node.rect.y + node.rect.h / 2;
		const result = await act(state.stateId, [{ action: "drag", path: [[node.rect.x + node.rect.w * 0.2, y], [node.rect.x + node.rect.w * 0.8, y]] }]);
		const now = await dom(pageA);
		return { result, effect: { ok: now.dragged.length === 1 && now.dragged[0] > 0, detail: `pointerdown-to-pointerup distances ${JSON.stringify(now.dragged)}, want one to the right` } };
	});

	// A second window of the same process becomes Chrome's key window; typing into the
	// first one must land there and nowhere else.
	const browser = await devtoolsSession(`ws://127.0.0.1:${chrome.port}${chrome.browserPath}`);
	await browser.send("Target.createTarget", { url: pageUrl("B"), newWindow: true });
	browser.close();
	const pageB = await pageSession(chrome, pageUrl("B"));
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
	await stopChrome(chrome);
	if (holder && killProcess(holder.pid, "SIGTERM")) await withTimeout(holder.exited, "the key holder to exit", 5_000).catch(() => killProcess(holder.pid));
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(root, { recursive: true, force: true });
}

const failed = cells.filter((entry) => entry.failures.length);
console.log(`${cells.length - failed.length}/${cells.length} web background cells passed`);
if (failed.length || cells.length === 0) process.exit(1);
