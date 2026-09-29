#!/usr/bin/env node
// The full loop against a real TextEdit window: find, observe, search, reject invalid
// payloads, wait, act with a verified postcondition, and fail honestly when it is not met.
// It also holds bcu to its evidence rule: an action counts as worked only when the platform
// can name the fact that moved. A key with no visible effect still succeeds, reported as
// unverified. Pressing Save straight from the menu bar root succeeds and the document
// file on disk shows that it saved; whether bcu could read evidence for it is not the contract,
// and the menu items bcu's own menu opening moved are not listed as changes.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { launchTextEdit, makeTemporaryRoot, monitorProcess, request, runCli, stopTextEdit, waitForAxWindow } from "./lib/harness.mjs";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP TextEdit smoke (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The TextEdit smoke test requires macOS.");

const fixtureDirectory = await makeTemporaryRoot("e2e-smoke");
const fixtureTitle = `bcu-smoke-${randomUUID()}`;
const fixtureName = `${fixtureTitle}.rtf`;
const fixturePath = path.join(fixtureDirectory, fixtureName);
// Rich text is what makes TextEdit show its format bar, the one real toolbar of toggles.
const initialText = [
	"{\\rtf1\\ansi\\ansicpg1252\\cocoartf2709",
	"{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;}",
	"{\\colortbl;\\red255\\green255\\blue255;}",
	"\\pard\\tx720\\pardirnatural\\partightenfactor0",
	"\\f0\\fs24 \\cf0 bcu smoke fixture}",
].join("\n");
const expectedText = `bcu smoke ${randomUUID()}`;
/** The Save menu item across the system languages this gate runs under. */
const SAVE_NAMES = ["保存", "存储", "Save"];
/** A key TextEdit binds to nothing. */
const INERT_KEY = "F8";
let createdPid;
let processMonitor;

async function expectCliFailure(stateId, action) {
	const result = await runCli(["act-ui", "--state", stateId, "-", "--json"], { input: `${JSON.stringify([action])}\n` });
	assert.equal(result.code, 2, `${action.action} invalid payload exited ${result.code}`);
	assert.equal(result.stdout, "", `${action.action} invalid payload wrote stdout`);
	assert.match(result.stderr, /^error invalid_arguments: .+/m);
	assert.match(result.stderr, /^recovery: .+/m);
}

/** Runs one act-ui through the public CLI, requires it to succeed, and returns its text view. */
async function expectSuccess(stateId, action, label) {
	const result = await runCli(["act-ui", "--state", stateId, "-"], { input: `${JSON.stringify([action])}\n` });
	assert.equal(result.code, 0, `${label} exited ${result.code}: ${result.stderr}`);
	return result.stdout;
}

/** Resolves once the file holds `text`; TextEdit writes it by replacing the file. */
async function waitForFileText(filePath, text, timeoutMs) {
	const holds = async () => (await fs.readFile(filePath, "utf8").catch(() => "")).includes(text);
	const stop = new AbortController();
	const timer = setTimeout(() => stop.abort(), timeoutMs);
	try {
		const events = fs.watch(path.dirname(filePath), { signal: stop.signal });
		if (await holds()) return true;
		for await (const _event of events) if (await holds()) return true;
	} catch (error) {
		if (error.name !== "AbortError") throw error;
	} finally {
		clearTimeout(timer);
	}
	return await holds();
}

async function cliJson(args) {
	const result = await runCli([...args, "--json"]);
	assert.equal(result.code, 0, `bcu ${args[0]} exited ${result.code}: ${result.stderr}`);
	return JSON.parse(result.stdout);
}

async function expectFailure(command, args, code) {
	try {
		await request(command, args);
		assert.fail(`${command} unexpectedly succeeded`);
	} catch (error) {
		assert.notEqual(error.code, 0, `${command} exited zero`);
		assert.equal(error.stdout, "", `${command} wrote a false success to stdout`);
		assert.match(error.stderr, new RegExp(`^error ${code}: .+`, "m"));
		assert.match(error.stderr, /^recovery: .+/m);
	}
}

try {
	await fs.writeFile(fixturePath, initialText);
	createdPid = await launchTextEdit(fixturePath);
	processMonitor = await monitorProcess(createdPid);
	await waitForAxWindow(createdPid, processMonitor.exited, fixtureTitle);

	const found = await request("find-roots", { pid: createdPid, kind: "window" });
	// TextEdit restores earlier documents into a fresh instance, so the fixture window is
	// the one named after the fixture, not simply the first root of this pid.
	const window = found.roots.find((candidate) => candidate.pid === createdPid && candidate.title.startsWith(fixtureTitle));
	assert(window, `TextEdit pid ${createdPid} did not expose a root titled ${fixtureTitle}`);
	const observed = await request("observe-ui", { root: window.ref, mode: "semantic" });
	assert.equal(observed.root.pid, createdPid, "observe-ui returned another root");
	assert(observed.nodes.every((node) => !/^ax/i.test(node.role)), "observation leaked raw accessibility roles");
	assert.equal(observed.image, undefined, "semantic observation produced an image");
	const editable = await request("search-ui", { stateId: observed.stateId, action: "setText", limit: 5 });
	const editor = editable.matches.find((match) => match.caps.includes("setText"));
	assert(editor, "TextEdit observation did not expose an editable element");
	for (const invalidAction of [
		{ action: "click", ref: 123 },
		{ action: "click", ref: editor.ref, button: "banana" },
		{ action: "click", ref: editor.ref, clickCount: "many" },
		{ action: "scroll", ref: editor.ref, scrollY: "abc" },
		{ action: "wait", ms: "soon" },
	]) await expectCliFailure(observed.stateId, invalidAction);
	const searched = await request("search-ui", { stateId: observed.stateId, role: "textarea", limit: 50 });
	assert.equal(searched.stateId, observed.stateId, "search-ui did not read the observed state");
	assert(searched.matches.length > 0, "search-ui did not return the observed text area");
	const waited = await request("wait-for", { stateId: observed.stateId, role: "AXTextArea", timeoutMs: 1_000 });
	assert.equal(waited.found, true, "wait-for did not find the existing text area");
	assert.doesNotThrow(() => JSON.stringify(waited), "wait-for returned a circular result");
	await expectFailure("wait-for", {
		stateId: observed.stateId,
		text: "__BCU_NEVER_EXISTS__",
		timeoutMs: 100,
	}, "action_timeout");
	const action = {
		stateId: observed.stateId,
		actions: [{ action: "setText", ref: editor.ref, text: expectedText }],
		expect: { value: expectedText, scope: editor.ref, timeoutMs: 5_000 },
	};
	const concurrent = await Promise.allSettled([
		request("act-ui", action),
		request("act-ui", action),
	]);
	const worked = concurrent.filter((result) => result.status === "fulfilled");
	const stale = concurrent.filter((result) => result.status === "rejected" && result.reason?.stderr?.includes("stale_state:"));
	assert.equal(worked.length, 1, `expected one successful concurrent action, got ${worked.length}`);
	assert.equal(stale.length, 1, `expected one stale_state rejection, got ${stale.length}`);
	const acted = worked[0].value;
	assert.equal(acted.outcome, "worked", "TextEdit setText was not reported as worked");
	assert.equal(acted.verification.status, "verified", "TextEdit expect did not observe a new value");
	assert.equal(acted.baseStateId, observed.stateId, "act-ui lost its base state");
	assert(JSON.stringify(acted.changes ?? acted.nodes ?? []).includes(expectedText), "successor view does not carry the written value");
	await expectFailure("act-ui", {
		stateId: acted.stateId,
		actions: [{ action: "wait", ms: 0 }],
		expect: { text: "__BCU_NEVER_EXISTS__", timeoutMs: 100 },
	}, "action_failed");
	// Nothing an agent can read moves when TextEdit ignores a key: it still exits zero, as
	// unverified. Save succeeds either way, and the file on disk is the witness that it ran.
	const keyState = await request("observe-ui", { root: window.ref, mode: "semantic" });
	const keyTarget = (await request("search-ui", { stateId: keyState.stateId, role: "textarea", limit: 1 })).matches[0];
	assert(keyTarget, "the document exposed no text area to send a key to");
	const keyLine = (await expectSuccess(keyState.stateId, { action: "keypress", ref: keyTarget.ref, keys: [INERT_KEY] }, `keypress ${INERT_KEY}`)).split("\n")[0];
	assert.match(keyLine, / · unverified via \w+$/, `keypress ${INERT_KEY} is not reported as unverified: ${keyLine}`);
	assert(!(await fs.readFile(fixturePath, "utf8")).includes(expectedText), "the fixture file already holds the edit before Save");
	const menuBar = (await cliJson(["find-roots", "--pid", String(createdPid), "--kind", "menubar"])).roots[0];
	assert(menuBar, `TextEdit pid ${createdPid} exposed no menu bar root`);
	const bar = await cliJson(["observe-ui", "--root", menuBar.ref]);
	let saveItem;
	for (const name of SAVE_NAMES) {
		saveItem ??= (await cliJson(["search-ui", "--state", bar.stateId, "--text", name, "--role", "menuitem"])).matches.find((match) => match.name === name);
	}
	assert(saveItem, `the TextEdit menu bar has no item named ${SAVE_NAMES.join(" / ")}`);
	const saved = await expectSuccess(bar.stateId, { action: "press", ref: saveItem.ref }, `pressing menu item '${saveItem.name}'`);
	// bcu opens and closes the menu to press the item; the menu items that come and go with
	// it are offscreen and outside the view, so they get no line of their own.
	assert(!/^- @e\d+/m.test(saved) && !/^\+ @e\d+ (in @e\d+ )?menu(item)?\b/m.test(saved), `pressing '${saveItem.name}' listed the menu items it moved:\n${saved}`);
	assert(await waitForFileText(fixturePath, expectedText, 10_000), `pressing '${saveItem.name}' did not write the edit to ${fixturePath}`);

	// Evidence: a toggle proves itself by its own value, and a click that only places a
	// caret proves itself by reaching the element that then holds focus.
	const formatted = await request("observe-ui", { root: window.ref, mode: "semantic" });
	const toggles = await request("search-ui", { stateId: formatted.stateId, role: "segment", limit: 20 });
	const toggle = toggles.matches.find((match) => match.caps.includes("toggle") && match.value === "0");
	assert(toggle, `the TextEdit format bar exposed no clear toggle: ${toggles.matches.map((match) => `${match.role} ${match.name}=${match.value} {${match.caps}}`).join(", ")}`);
	const toggled = await request("act-ui", { stateId: formatted.stateId, actions: [{ action: "press", ref: toggle.ref }] });
	assert.equal(toggled.outcome, "worked", `pressing toggle '${toggle.name}' was not reported as worked`);
	assert.deepEqual(
		{ source: toggled.verification.evidence?.source, field: toggled.verification.evidence?.field, from: toggled.verification.evidence?.from, to: toggled.verification.evidence?.to },
		{ source: "ax", field: "value", from: "0", to: "1" },
		`pressing toggle '${toggle.name}' did not report the value that moved: ${JSON.stringify(toggled.verification.evidence)}`,
	);
	const restored = await request("act-ui", { stateId: toggled.stateId, actions: [{ action: "press", ref: toggle.ref }] });
	assert.equal(restored.verification.evidence?.to, "0", `toggle '${toggle.name}' did not return to its original value`);

	const caretState = await request("observe-ui", { root: window.ref, mode: "semantic" });
	const textArea = caretState.nodes.find((node) => node.role === "textarea") ?? (await request("search-ui", { stateId: caretState.stateId, role: "textarea", limit: 1 })).matches[0];
	assert(textArea, "the RTF document exposed no text area to click into");
	const firstClick = await request("act-ui", { stateId: caretState.stateId, actions: [{ action: "click", ref: textArea.ref }] });
	assert.equal(firstClick.outcome, "worked", "clicking into the text area was not reported as worked");
	const secondClick = await request("act-ui", { stateId: firstClick.stateId, actions: [{ action: "click", ref: textArea.ref }] });
	assert.equal(secondClick.outcome, "worked", "a repeated click into the focused text area lost its evidence");
	assert.equal(secondClick.verification.evidence?.source, "focus", `a caret-only click reported ${JSON.stringify(secondClick.verification.evidence)} instead of reaching the focused element`);

	console.log(`PASS TextEdit stdin validation → wait errors → concurrent act → postcondition error → unverified key and a Save that wrote the file → toggle and caret evidence in isolated pid ${createdPid}`);
} finally {
	if (createdPid) await stopTextEdit(createdPid, processMonitor);
	await fs.rm(fixtureDirectory, { recursive: true, force: true });
}
