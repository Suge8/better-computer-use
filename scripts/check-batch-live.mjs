#!/usr/bin/env node
// act-ui across user interface, on a real app. The subject is a window with a font popup and a
// "New note…" button that raises a sheet. Choosing a dropdown option takes two commands: the
// press that opens the popup returns the menu it opened, already observed, and the next
// act-ui presses the option in that view. A whole dialog is one array: press the button,
// find the sheet's Name field and fill it, find Create and press it, and check the window's
// label afterwards, each element found in the root it lives in when its step runs. The
// popup's menu hangs under the popup in the window's own tree, yet the result reports it once,
// as the opened root, and choosing an option reports the window as what changed (the popup's
// new value), not folded whole. A step that closes the state's own root (the sheet's button)
// does not end the array: the next step types into the window the app shows now. Wait-for reads three periods as the ellipsis the button's title ends in.
// Throughout, a stand-in for the user's front app keeps the front and its keyboard. Refusal of
// ambiguous locators and the rules of matching are held by the golden files and the daemon tests.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { desktop, killProcess, launchBatchForm, launchKeyHolder, makeTemporaryRoot, residentEnvironment, runCli, waitForAxWindow, withTimeout } from "./lib/harness.mjs";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP batch (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The batch test requires macOS.");

const root = await makeTemporaryRoot("batch");
const env = residentEnvironment(path.join(root, "resident.sock"), 30_000);
const title = `bcu batch ${randomUUID().slice(0, 8)}`;
const logPath = path.join(root, "form.log");
let form;
let holder;

async function bcu(args, input) {
	const result = await runCli([...args, "--json"], { input, env });
	if (result.code !== 0) throw new Error(`bcu ${args[0]} exited ${result.code}: ${result.stderr.trim()}`);
	return JSON.parse(result.stdout);
}

async function act(stateId, actions) {
	return await bcu(["act-ui", "--state", stateId, "-"], JSON.stringify(actions));
}

async function logged() {
	return (await fs.readFile(logPath, "utf8")).split("\n").filter(Boolean);
}

async function windowState(rootRef) {
	return await bcu(["observe-ui", "--root", rootRef]);
}

/**
 * Hands the front to the key holder and returns a check that it still holds it after the cell.
 * An open popup menu takes the key window while it is open (AppKit menu tracking, the same
 * for a plain ref press), so a cell that leaves a menu open passes `menuOpen` and is held to
 * the front app and the pointer only.
 */
async function userInFront() {
	const seen = (await holder.takeFront()).length;
	const before = await desktop();
	assert.equal(before.front, holder.pid, "the key holder did not take the front");
	return async (cell, { menuOpen = false } = {}) => {
		const after = await desktop();
		assert.equal(after.front, holder.pid, `${cell} changed the front app`);
		assert.deepEqual([after.x, after.y], [before.x, before.y], `${cell} moved the real pointer`);
		if (!menuOpen) assert.deepEqual((await holder.logged()).slice(seen), [], `${cell} made the user's front app lose its key window or activation`);
	};
}

try {
	holder = await launchKeyHolder(root);
	form = await launchBatchForm(root, logPath, title);
	await waitForAxWindow(form.pid, form.exited, title);
	const window = (await bcu(["find-roots", "--pid", String(form.pid), "--kind", "window"])).roots.find((candidate) => candidate.title === title);
	assert(window, "the form window is not listed");

	// A dropdown option in two commands.
	let untouched = await userInFront();
	const closedForm = await windowState(window.ref);
	const pressed = await act(closedForm.stateId, [{ action: "press", find: { role: "popup", name: "Font" } }]);
	assert(pressed.opened, `the press that opened the popup did not return its menu: ${JSON.stringify(pressed)}`);
	assert.equal(pressed.opened.root.kind, "menu");
	assert.deepEqual(pressed.changes, [], "the menu under the popup was reported again as changes of the window");
	assert.deepEqual(pressed.opened.nodes.filter((node) => node.role === "menuitem").map((node) => node.name), ["Helvetica", "Times", "Courier"]);
	const times = pressed.opened.nodes.find((node) => node.name === "Times");
	const chosen = await act(pressed.opened.stateId, [{ action: "press", ref: times.ref }]);
	assert.deepEqual(await logged(), ["font Times"], "choosing the option did not reach the app");
	assert.equal(chosen.closed?.[0]?.ref, pressed.opened.root.ref, "choosing the option did not report the menu closing");
	assert.equal(chosen.next?.ref, window.ref, "the window is not the root to continue in");
	assert.equal(chosen.nodes, undefined, "the window was folded whole although it was seen before");
	assert(chosen.changes.some((change) => change.type === "updated" && change.fields?.value === "Times"), `the popup's new value is not among the changes: ${JSON.stringify(chosen.changes)}`);
	assert.deepEqual(chosen.changes.filter((change) => change.type !== "updated"), [], "the closed menu was reported as nodes added or removed");
	await untouched("choosing a dropdown option", { menuOpen: true });

	// A dialog in one array.
	untouched = await userInFront();
	const filled = await act((await windowState(window.ref)).stateId, [
		{ action: "press", find: { role: "button", name: "New note…" } },
		{ action: "setText", text: "Report", find: { role: "textfield", name: "Name", root: "opened" } },
		{ action: "press", find: { role: "button", name: "Create", root: "opened" }, expect: { text: "note: Report", root: "state" } },
	]);
	assert.deepEqual((await logged()).slice(1), ["created Report"], "the dialog did not run to its end");
	assert.equal(filled.closed?.[0]?.kind, "sheet");
	assert.equal(filled.verification.status, "verified");
	await untouched("filling in a dialog");

	// The state's own root closes in the middle of the array; the array goes on in the window the app shows now.
	untouched = await userInFront();
	await act((await windowState(window.ref)).stateId, [{ action: "press", find: { name: "New note…" } }]);
	const sheet = (await bcu(["find-roots", "--pid", String(form.pid), "--kind", "sheet"])).roots[0];
	assert(sheet, "the sheet is not listed");
	const sheetState = await windowState(sheet.ref);
	const typed = await act(sheetState.stateId, [
		{ action: "press", ref: sheetState.nodes.find((node) => node.name === "Open document").ref },
		{ action: "typeText", text: "hello", find: { role: "textarea", name: "Body", root: "opened" } },
	]);
	assert.equal(typed.closed?.[0]?.ref, sheet.ref, "the sheet closing was not reported");
	assert.match(typed.next?.title ?? "", /note$/, `the result does not follow the document window: ${JSON.stringify(typed.next)}`);
	assert.equal((await logged()).at(-1), "typed hello", "the text did not reach the window the sheet's button opened");
	await untouched("typing into the window opened by a closing sheet");

	// Wait-for reads three periods as the ellipsis.
	const final = await windowState(window.ref);
	await bcu(["wait-for", "--state", final.stateId, "--text", "New note...", "--timeout", "2000"]);

	console.log(`PASS popup press returned its menu, option chosen in the next command → a dialog opened, filled and confirmed in one array → a step closing the state's root, the next typing in the window that opened → the menu reported once → three periods match the ellipsis in wait-for → the user's front app kept the front throughout (pid ${form.pid})`);
} finally {
	if (form && killProcess(form.pid, "SIGTERM")) await withTimeout(form.exited, "the form to exit", 5_000).catch(() => killProcess(form.pid));
	if (holder && killProcess(holder.pid, "SIGTERM")) await withTimeout(holder.exited, "the key holder to exit", 5_000).catch(() => killProcess(holder.pid));
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(root, { recursive: true, force: true });
}
