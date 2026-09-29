#!/usr/bin/env node
// A window with no accessibility content is still operable through the same observe → act
// loop. The subject draws its own Chinese text buttons and exposes nothing to
// Accessibility; a default observation must read them on screen as `ocr` nodes that can be
// pressed. Pressing one lands exactly once in the background, even though the view
// rejects a first click on an inactive window, and succeeds on the window's own pixels
// changing. A press that changes nothing on screen is reported as unverified and never replayed.
// A plain click at a point over the window's one native toggle is pressed like its ref and
// judged on the toggle's value. Throughout, a stand-in for the user's front app keeps the
// front and its keyboard. A self-drawn input that shows its search results only while its app is active
// shows them after a background click and typing, because bcu's background click makes the
// app believe it is active; `--foreground` delivers the same array in the foreground. A
// window that does expose accessibility content keeps the capture-free default look.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import {
	residentEnvironment,
	desktop,
	killProcess,
	launchDrawnButtons,
	launchDrawnInput,
	launchKeyHolder,
	launchTextEdit,
	makeTemporaryRoot,
	monitorProcess,
	runCli,
	stopTextEdit,
	waitForAxWindow,
	withTimeout,
} from "./lib/harness.mjs";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP OCR targets (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The OCR target test requires macOS.");

const root = await makeTemporaryRoot("ocr-targets");
const env = residentEnvironment(path.join(root, "resident.sock"), 30_000);
const title = `bcu drawn ${randomUUID().slice(0, 8)}`;
const logPath = path.join(root, "pressed.log");
let drawn;
let drawnInput;
let holder;
let textEditPid;
let textEditMonitor;

async function bcu(args, input) {
	const result = await runCli([...args, "--json"], { input, env });
	if (result.code !== 0) throw new Error(`bcu ${args[0]} exited ${result.code}: ${result.stderr.trim()}`);
	return JSON.parse(result.stdout);
}

/**
 * Hands the front to the key holder, the stand-in for the user's app, and returns a check
 * that it still holds the front and its keyboard after the cell.
 */
async function userInFront() {
	const logged = (await holder.takeFront()).length;
	const before = await desktop();
	assert.equal(before.front, holder.pid, "the key holder did not take the front");
	return async (cell) => {
		const after = await desktop();
		assert.equal(after.front, holder.pid, `${cell} changed the front app`);
		assert.deepEqual([after.x, after.y], [before.x, before.y], `${cell} moved the real pointer`);
		assert.deepEqual((await holder.logged()).slice(logged), [], `${cell} made the user's front app lose its key window or activation`);
	};
}

async function pressedLabels() {
	return (await fs.readFile(logPath, "utf8")).split("\n").filter(Boolean);
}

async function press(stateId, ref) {
	return await runCli(["act-ui", "--state", stateId, "-", "--json"], { input: `${JSON.stringify([{ action: "press", ref }])}\n`, env });
}

async function actWithCoordinates(stateId, rect) {
	return await runCli(["act-ui", "--state", stateId, "-", "--json"], { input: `${JSON.stringify([{ action: "click", x: rect.x + rect.w / 2, y: rect.y + rect.h / 2 }])}\n`, env });
}

/** Runs one act-ui and returns its result; `name` says which step failed. */
async function act(name, stateId, actions, flags = []) {
	const run = await runCli(["act-ui", "--state", stateId, ...flags, "-", "--json"], { input: `${JSON.stringify(actions)}\n`, env });
	assert.equal(run.code, 0, `${name} exited ${run.code}: ${run.stderr}`);
	return JSON.parse(run.stdout);
}

/** The current state of `rootRef` and the rect of the node read as `name`. */
async function located(rootRef, name) {
	const state = await bcu(["observe-ui", "--root", rootRef]);
	const node = state.nodes.find((candidate) => candidate.name === name);
	assert(node, `the observation has no node named ${name}: ${JSON.stringify(state.nodes.map((candidate) => [candidate.role, candidate.name]))}`);
	const { rect } = (await bcu(["inspect-ui", "--state", state.stateId, "--ref", node.ref])).node;
	return { state, rect, center: { x: rect.x + rect.w / 2, y: rect.y + rect.h / 2 } };
}

/** What the fixture logged after the first `seen` lines, that start with `prefix`. */
async function loggedSince(seen, prefix) {
	return (await pressedLabels()).slice(seen).filter((line) => line.startsWith(prefix));
}

try {
	holder = await launchKeyHolder(root);
	drawn = await launchDrawnButtons(root, logPath, title);
	await waitForAxWindow(drawn.pid, drawn.exited, title);
	const found = await bcu(["find-roots", "--pid", String(drawn.pid), "--kind", "window"]);
	const window = found.roots.find((candidate) => candidate.title === title);
	assert(window, `bcu found no window titled ${title}`);

	// The default observation reads the drawn labels, in Chinese, as their own nodes.
	const observed = await bcu(["observe-ui", "--root", window.ref]);
	const labelled = (name) => observed.nodes.find((node) => node.name === name);
	for (const name of ["发送", "取消"]) {
		const node = labelled(name);
		assert(node, `the default observation has no node named ${name}: ${JSON.stringify(observed.nodes.map((candidate) => [candidate.role, candidate.name]))}`);
		assert.equal(node.role, "ocr", `${name} is not marked as read from the screen`);
		assert.deepEqual(node.caps, ["press"], `${name} promises ${node.caps} instead of a press only`);
	}
	const send = labelled("发送");
	const searched = await bcu(["search-ui", "--state", observed.stateId, "--text", "发送"]);
	assert.deepEqual(searched.matches.map((match) => [match.ref, match.role, match.caps]), [[send.ref, "ocr", ["press"]]], "search-ui disagrees with the view about 发送");
	const inspected = await bcu(["inspect-ui", "--state", observed.stateId, "--ref", send.ref]);
	assert.equal(inspected.node.title, "发送", "inspect-ui disagrees with the view about 发送");

	// The press lands in the background: the user's app keeps the front and its keyboard, and
	// the real pointer stays put. Nothing Accessibility can read changes, so the window's own
	// pixels are the evidence, and the successor view already shows what the press drew.
	const sendUntouched = await userInFront();
	const pressed = await press(observed.stateId, send.ref);
	assert.deepEqual(await pressedLabels(), ["发送"], "the drawn app did not record exactly one 发送");
	assert.equal(pressed.code, 0, `pressing 发送 exited ${pressed.code}: ${pressed.stderr}`);
	const result = JSON.parse(pressed.stdout);
	assert.equal(result.delivery, "pid", `pressing 发送 was delivered via ${result.delivery}`);
	assert.equal(result.verification.evidence?.source, "screen", `pressing 发送 was judged on ${JSON.stringify(result.verification.evidence)}`);
	assert((result.changes ?? result.nodes ?? []).length > 0, "the successor view does not show what the press changed");
	await sendUntouched("pressing 发送");

	// A press that draws nothing has no evidence: it succeeds as unverified and is not replayed.
	const quiet = await bcu(["observe-ui", "--root", window.ref]);
	const silent = quiet.nodes.find((node) => node.name === "静默");
	assert(silent, `the observation after the press lost 静默: ${JSON.stringify(quiet.nodes.map((node) => node.name))}`);
	const silentUntouched = await userInFront();
	const unproven = await press(quiet.stateId, silent.ref);
	assert.deepEqual(await pressedLabels(), ["发送", "静默"], "静默 was not pressed exactly once");
	assert.equal(unproven.code, 0, `pressing 静默 exited ${unproven.code}: ${unproven.stderr}`);
	assert.equal(JSON.parse(unproven.stdout).outcome, "unknown", `a press with no evidence claimed ${JSON.parse(unproven.stdout).outcome}`);
	await silentUntouched("pressing 静默");

	// A plain click at a point over a native control is pressed like its ref: in the
	// background, judged on the control's own value, never on the screen.
	const axView = await bcu(["observe-ui", "--root", window.ref]);
	const nativeToggle = axView.nodes.find((node) => node.name === "原生" && node.role !== "ocr");
	assert(nativeToggle, `the fixture exposed no native 原生 toggle: ${JSON.stringify(axView.nodes.map((node) => [node.role, node.name]))}`);
	const nativeRect = (await bcu(["inspect-ui", "--state", axView.stateId, "--ref", nativeToggle.ref])).node.rect;
	const nativeUntouched = await userInFront();
	const nativePressed = await actWithCoordinates(axView.stateId, nativeRect);
	assert.deepEqual(await pressedLabels(), ["发送", "静默", "原生"], "the native toggle was not toggled exactly once");
	assert.equal(nativePressed.code, 0, `clicking over 原生 exited ${nativePressed.code}: ${nativePressed.stderr}`);
	const nativeResult = JSON.parse(nativePressed.stdout);
	assert.deepEqual([nativeResult.delivery, nativeResult.verification.evidence?.source, nativeResult.verification.evidence?.field], ["ax", "ax", "value"], `clicking over 原生 was ${JSON.stringify([nativeResult.delivery, nativeResult.verification.evidence])}`);
	await nativeUntouched("the click over 原生");



	// Results that appear only while the app is active appear after a background click and
	// typing, and the user's app keeps the front. `--foreground` activates the app instead.
	const inputTitle = `bcu drawn input ${randomUUID().slice(0, 8)}`;
	const inputEvents = path.join(root, "input-events.log");
	drawnInput = await launchDrawnInput(root, path.join(root, "input.log"), inputTitle, inputEvents);
	await waitForAxWindow(drawnInput.pid, drawnInput.exited, inputTitle);
	const inputRoot = (await bcu(["find-roots", "--pid", String(drawnInput.pid), "--kind", "window"])).roots.find((candidate) => candidate.title === inputTitle);
	const popups = async () => (await fs.readFile(inputEvents, "utf8")).split("\n").filter((line) => line.startsWith("popup "));
	const searchBox = await located(inputRoot.ref, "输入区");
	const popupUntouched = await userInFront();
	await act("typing into the drawn input", searchBox.state.stateId, [{ action: "click", ...searchBox.center }, { action: "typeText", text: "abc" }]);
	assert.equal((await popups()).at(-1), "popup abc", "results that need an active app did not appear after background typing");
	await popupUntouched("typing into the drawn input");
	const again = await located(inputRoot.ref, "输入区");
	await holder.takeFront();
	const shownBefore = (await popups()).length;
	const foreground = await act("typing into the drawn input with --foreground", again.state.stateId, [{ action: "click", ...again.center }, { action: "typeText", text: "d" }], ["--foreground"]);
	assert.equal(foreground.delivery, "hid", `--foreground delivered via ${foreground.delivery}`);
	assert.equal((await desktop()).front, drawnInput.pid, "--foreground did not bring the drawn input's app to the front");
	assert.deepEqual((await popups()).slice(shownBefore), ["popup abcd"], "typing with --foreground did not show the results");

	// A window with accessibility content keeps the capture-free default look.
	const documentDirectory = path.join(root, "doc");
	await fs.mkdir(documentDirectory);
	const documentTitle = `bcu-ocr-${randomUUID()}`;
	await fs.writeFile(path.join(documentDirectory, `${documentTitle}.txt`), "plain accessible text\n");
	textEditPid = await launchTextEdit(path.join(documentDirectory, `${documentTitle}.txt`));
	textEditMonitor = await monitorProcess(textEditPid);
	await waitForAxWindow(textEditPid, textEditMonitor.exited, documentTitle);
	const document = (await bcu(["find-roots", "--pid", String(textEditPid), "--kind", "window"])).roots.find((candidate) => candidate.title.startsWith(documentTitle));
	const documentView = await bcu(["observe-ui", "--root", document.ref]);
	assert(!documentView.nodes.some((node) => node.role === "ocr"), "an accessible window was read from the screen by default");
	assert.equal(documentView.image, undefined, "the default look of an accessible window captured an image");

	console.log(`PASS drawn window read as ocr nodes → search and inspect agree → background press landed once on screen evidence → silent press reported unverified → click over a native toggle pressed it in the background → the user's front app kept the front and its keyboard throughout → results that need an active app appeared after background typing, and --foreground delivered in the foreground → accessible window stays capture-free (pid ${drawn.pid})`);
} finally {
	for (const fixture of [drawn, drawnInput]) {
		if (fixture && killProcess(fixture.pid, "SIGTERM")) await withTimeout(fixture.exited, "the drawn fixture to exit", 5_000).catch(() => killProcess(fixture.pid));
	}
	if (holder && killProcess(holder.pid, "SIGTERM")) await withTimeout(holder.exited, "the key holder to exit", 5_000).catch(() => killProcess(holder.pid));
	if (textEditPid) await stopTextEdit(textEditPid, textEditMonitor);
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(root, { recursive: true, force: true });
}
