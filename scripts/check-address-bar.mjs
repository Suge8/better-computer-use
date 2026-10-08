#!/usr/bin/env node
// A URL and a line break typed into the address bar of Chrome navigate, in the background and
// with --foreground: the line break is the real Return key, which the address bar acts on,
// where a character on key code 0 is ignored. A dedicated Google Chrome shows a page whose
// input holds the keyboard focus, and the user's front app keeps the front until the action.
import fs from "node:fs/promises";
import path from "node:path";
import { launchChrome, pageSession, stopChrome } from "./lib/chrome.mjs";
import { residentEnvironment, killProcess, launchKeyHolder, makeTemporaryRoot, runCli, withTimeout } from "./lib/harness.mjs";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP address bar typing (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The address bar gate requires macOS.");

const root = await makeTemporaryRoot("address-bar");
const env = residentEnvironment(path.join(root, "resident.sock"), 60_000);
const cells = [];
let chrome;
let holder;
let page;

async function bcu(args, input) {
	const result = await runCli([...args, "--json"], { input, env });
	if (result.code !== 0) throw new Error(`bcu ${args[0]} exited ${result.code}: ${result.stderr.trim()}`);
	return JSON.parse(result.stdout);
}

const evaluate = async (expression) => (await page.send("Runtime.evaluate", { expression, returnByValue: true })).result.value;

/**
 * A fresh observation of the Chrome window, and its address bar. Chrome exposes the toolbar a
 * moment after launch and says nothing when, so the look is repeated until it is there.
 */
async function addressBar() {
	for (let attempt = 0; attempt < 40; attempt++) {
		const found = await bcu(["find-roots", "--pid", String(chrome.child.pid), "--kind", "window"]);
		const window = found.roots.find((candidate) => candidate.title.endsWith("Google Chrome"));
		if (!window) continue;
		const state = await bcu(["observe-ui", "--root", window.ref]);
		const bar = (await bcu(["search-ui", "--state", state.stateId, "--role", "textfield", "--limit", "10"])).matches.find((match) => /address/i.test(match.name));
		if (bar) return { state, ref: bar.ref, value: bar.value };
		await new Promise((resolve) => setTimeout(resolve, 250));
	}
	throw new Error("Chrome's address bar was not found");
}

async function waitForTitle(title) {
	while ((await evaluate("document.title")) !== title) await new Promise((resolve) => setTimeout(resolve, 100));
	return title;
}

/** Focuses the page's input, hands the front to the user's app, and types `text` over the address bar's content. */
async function typeIntoAddressBar(text, flags) {
	await page.send("Page.bringToFront");
	await evaluate(`document.getElementById("field").focus()`);
	await withTimeout((async () => {
		while (!(await evaluate(`document.hasFocus() && document.activeElement.id === "field"`))) await new Promise((resolve) => setTimeout(resolve, 50));
	})(), "the page input to hold focus", 5_000);
	// Chrome records the focused view in its browser process a moment after the page reports
	// it, and nothing announces when.
	await new Promise((resolve) => setTimeout(resolve, 300));
	await holder.takeFront();
	const { state, ref } = await addressBar();
	const actions = [{ action: "keypress", ref, keys: ["cmd", "a"] }, { action: "typeText", ref, text }];
	return await runCli(["act-ui", "--state", state.stateId, ...flags, "-", "--json"], { input: `${JSON.stringify(actions)}\n`, env });
}

async function cell(name, run) {
	const failures = [];
	try {
		await run(failures);
	} catch (error) {
		failures.push(error.message);
	}
	cells.push({ name, failures });
	console.log(`${failures.length ? "FAIL" : "PASS"} ${name}${failures.map((failure) => `\n  - ${failure}`).join("")}`);
}

try {
	await fs.writeFile(path.join(root, "start.html"), '<!doctype html><title>start page</title><input id="field" aria-label="Page field" autofocus>');
	await fs.writeFile(path.join(root, "target.html"), "<!doctype html><title>target page</title><p>target</p>");
	const start = `file://${path.join(root, "start.html")}`;
	const target = `file://${path.join(root, "target.html")}`;
	holder = await launchKeyHolder(root);
	chrome = await launchChrome(path.join(root, "profile"), start, (spawned) => { chrome = spawned; });
	page = await pageSession(chrome, start);

	await addressBar();
	for (const flags of [[], ["--foreground"]]) {
		await cell(`a URL and a line break typed ${flags.length ? "with --foreground" : "in the background"} navigate`, async (failures) => {
			await page.send("Page.navigate", { url: start });
			await withTimeout(waitForTitle("start page"), "Chrome to show the start page", 5_000);
			const run = await typeIntoAddressBar(`${target}\n`, flags);
			if (run.code !== 0) failures.push(`act-ui exited ${run.code}: ${run.stderr.trim()}`);
			const title = await withTimeout(waitForTitle("target page"), "Chrome to show the target page", 5_000).catch(() => evaluate("document.title"));
			if (title !== "target page") failures.push(`the page shows ${JSON.stringify(title)}, want the target page`);
		});
	}
} finally {
	page?.close();
	await stopChrome(chrome);
	if (holder && killProcess(holder.pid, "SIGTERM")) await withTimeout(holder.exited, "the key holder to exit", 5_000).catch(() => killProcess(holder.pid));
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(root, { recursive: true, force: true });
}

const failed = cells.filter((entry) => entry.failures.length);
console.log(`${cells.length - failed.length}/${cells.length} address bar cells passed`);
if (failed.length || cells.length === 0) process.exit(1);
