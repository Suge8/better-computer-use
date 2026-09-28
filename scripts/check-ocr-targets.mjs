#!/usr/bin/env node
// A window with no accessibility content is still operable through the same observe → act
// loop. The subject draws its own Chinese text buttons and exposes nothing to
// Accessibility; a default observation must read them on screen as `ocr` nodes that can be
// pressed. Pressing one lands exactly once in the background, even though the view
// rejects a first click on an inactive window, and succeeds on the window's own pixels
// changing. A press that changes nothing on screen fails honestly and is never replayed.
// A plain click at a point over the window's one native toggle is pressed like its ref and
// judged on the toggle's value. The user's front app keeps the front and its keyboard
// through a background press. A window that does expose accessibility content keeps the
// capture-free default look.
import assert from "node:assert/strict";
import { execFile as execFileCallback } from "node:child_process";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import {
	brokerEnvironment,
	buildBundle,
	killProcess,
	launchDrawnButtons,
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

const execFile = promisify(execFileCallback);
const root = await makeTemporaryRoot("ocr-targets");
const env = brokerEnvironment(path.join(root, "broker.sock"), 30_000);
const title = `bcu drawn ${randomUUID().slice(0, 8)}`;
const logPath = path.join(root, "pressed.log");
const holderLogPath = path.join(root, "holder.log");
let drawn;
let textEditPid;
let textEditMonitor;

async function bcu(args, input) {
	const result = await runCli([...args, "--json"], { input, env });
	if (result.code !== 0) throw new Error(`bcu ${args[0]} exited ${result.code}: ${result.stderr.trim()}`);
	return JSON.parse(result.stdout);
}

/** Front application and real pointer, read by a process that is not bcu. */
async function desktop() {
	const { stdout } = await execFile("osascript", ["-l", "JavaScript", "-e", [
		"ObjC.import('AppKit')",
		"const m = $.NSEvent.mouseLocation",
		"JSON.stringify({ front: $.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier, x: m.x, y: m.y })",
	].join(";")]);
	return JSON.parse(stdout);
}

async function frontFinder() {
	await execFile("osascript", ["-l", "JavaScript", "-e", "Application('Finder').activate()"]);
	const { stdout } = await execFile("pgrep", ["-x", "Finder"]);
	const now = await desktop();
	assert.equal(now.front, Number(stdout.trim()), "Finder did not come to the front");
	return now;
}

async function pressedLabels() {
	return (await fs.readFile(logPath, "utf8")).split("\n").filter(Boolean);
}

async function press(stateId, ref) {
	return await runCli(["act-ui", "--state", stateId, "-", "--json"], { input: `${JSON.stringify([{ action: "press", ref }])}\n`, env });
}

/** One raw helper request, to read what the look itself did rather than what the view shows. */
function helper(cmd, payload) {
	const socketPath = path.join(os.homedir(), "Library/Caches/bcu/bridge.sock");
	return withTimeout(new Promise((resolve, reject) => {
		const socket = net.createConnection(socketPath);
		let buffer = "";
		socket.setEncoding("utf8");
		socket.on("connect", () => socket.write(`${JSON.stringify({ id: `ocr-${randomUUID()}`, cmd, ...payload })}\n`));
		socket.on("data", (chunk) => {
			buffer += chunk;
			const newline = buffer.indexOf("\n");
			if (newline < 0) return;
			socket.end();
			const parsed = JSON.parse(buffer.slice(0, newline));
			if (parsed.ok) resolve(parsed.result);
			else reject(new Error(parsed.error?.message ?? `${cmd} failed`));
		});
		socket.on("error", reject);
	}), `the helper ${cmd}`, 20_000);
}

function walk(node, visit) {
	visit(node);
	for (const child of node.children ?? []) walk(child, visit);
}

async function actWithCoordinates(stateId, rect) {
	return await runCli(["act-ui", "--state", stateId, "-", "--json"], { input: `${JSON.stringify([{ action: "click", x: rect.x + rect.w / 2, y: rect.y + rect.h / 2 }])}\n`, env });
}

try {
	await buildBundle();
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

	// The press lands in the background: Finder stays in front and the real pointer stays
	// put. Nothing Accessibility can read changes, so the window's own pixels are the
	// evidence, and the successor view already shows what the press drew.
	const before = await frontFinder();
	const pressed = await press(observed.stateId, send.ref);
	const after = await desktop();
	assert.deepEqual(await pressedLabels(), ["发送"], "the drawn app did not record exactly one 发送");
	assert.equal(pressed.code, 0, `pressing 发送 exited ${pressed.code}: ${pressed.stderr}`);
	const result = JSON.parse(pressed.stdout);
	assert.equal(result.delivery, "pid", `pressing 发送 was delivered via ${result.delivery}`);
	assert.equal(result.verification.evidence?.source, "screen", `pressing 发送 was judged on ${JSON.stringify(result.verification.evidence)}`);
	assert((result.changes ?? result.nodes ?? []).length > 0, "the successor view does not show what the press changed");
	assert.equal(after.front, before.front, "the background press changed the front app");
	assert.deepEqual([after.x, after.y], [before.x, before.y], "the background press moved the real pointer");

	// A press that draws nothing has no evidence: it fails honestly and is not replayed.
	const quiet = await bcu(["observe-ui", "--root", window.ref]);
	const silent = quiet.nodes.find((node) => node.name === "静默");
	assert(silent, `the observation after the press lost 静默: ${JSON.stringify(quiet.nodes.map((node) => node.name))}`);
	await frontFinder();
	const unproven = await press(quiet.stateId, silent.ref);
	assert.deepEqual(await pressedLabels(), ["发送", "静默"], "静默 was not pressed exactly once");
	assert.equal(unproven.code, 9, `pressing 静默 exited ${unproven.code}: ${unproven.stdout}`);
	assert.equal(unproven.stdout, "", "a press with no evidence wrote a success to stdout");
	assert.match(unproven.stderr, /^recovery: .*may already have taken effect/m, "the failure does not warn that the press may have landed");

	// A plain click at a point over a native control is pressed like its ref: in the
	// background, judged on the control's own value, never on the screen.
	const axView = await bcu(["observe-ui", "--root", window.ref]);
	const nativeToggle = axView.nodes.find((node) => node.name === "原生" && node.role !== "ocr");
	assert(nativeToggle, `the fixture exposed no native 原生 toggle: ${JSON.stringify(axView.nodes.map((node) => [node.role, node.name]))}`);
	const nativeRect = (await bcu(["inspect-ui", "--state", axView.stateId, "--ref", nativeToggle.ref])).node.rect;
	const nativeBefore = await frontFinder();
	const nativePressed = await actWithCoordinates(axView.stateId, nativeRect);
	const nativeAfter = await desktop();
	assert.deepEqual(await pressedLabels(), ["发送", "静默", "原生"], "the native toggle was not toggled exactly once");
	assert.equal(nativePressed.code, 0, `clicking over 原生 exited ${nativePressed.code}: ${nativePressed.stderr}`);
	const nativeResult = JSON.parse(nativePressed.stdout);
	assert.deepEqual([nativeResult.delivery, nativeResult.verification.evidence?.source, nativeResult.verification.evidence?.field], ["ax", "ax", "value"], `clicking over 原生 was ${JSON.stringify([nativeResult.delivery, nativeResult.verification.evidence])}`);
	assert.equal(nativeAfter.front, nativeBefore.front, "the click over 原生 changed the front app");
	assert.deepEqual([nativeAfter.x, nativeAfter.y], [nativeBefore.x, nativeBefore.y], "the click over 原生 moved the real pointer");

	// The user's own front app keeps both the front and its keyboard through a background
	// press on screen evidence.
	const holder = await launchKeyHolder(root, holderLogPath);
	try {
		const cancelView = await bcu(["observe-ui", "--root", window.ref]);
		const cancel = cancelView.nodes.find((node) => node.name === "取消");
		assert(cancel, `the observation lost 取消: ${JSON.stringify(cancelView.nodes.map((node) => node.name))}`);
		const cancelled = await press(cancelView.stateId, cancel.ref);
		assert.equal(cancelled.code, 0, `pressing 取消 exited ${cancelled.code}: ${cancelled.stderr}`);
		assert.deepEqual(await pressedLabels(), ["发送", "静默", "原生", "取消"], "取消 was not pressed exactly once");
		assert.equal((await desktop()).front, holder.pid, "the background press took the front from the user's app");
		assert.deepEqual((await fs.readFile(holderLogPath, "utf8")).split("\n").filter(Boolean), [], "the user's front app lost its key window or activation");
	} finally {
		if (killProcess(holder.pid, "SIGTERM")) await withTimeout(holder.exited, "the key holder to exit", 5_000).catch(() => killProcess(holder.pid));
	}

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
	const helperRoot = (await helper("listRoots", { pid: textEditPid })).roots.find((candidate) => candidate.title.startsWith(documentTitle));
	const look = await helper("look", { rootRef: helperRoot.rootRef, windowId: helperRoot.windowId, readText: "auto", includeImage: false });
	assert.equal(look.image, undefined, "the default look of an accessible window captured an image");
	assert.equal(look.readText?.executed, false, "the default look of an accessible window ran OCR");
	let pictureNodes = 0;
	walk(look.outline, (node) => { if (node.pictureOnly) pictureNodes += 1; });
	assert.equal(pictureNodes, 0, "the default look of an accessible window grew OCR nodes");

	console.log(`PASS drawn window read as ocr nodes → search and inspect agree → background press landed once on screen evidence → silent press failed honestly → click over a native toggle pressed it in the background → the user's front app kept the front and its keyboard → accessible window stays capture-free (pid ${drawn.pid})`);
} finally {
	if (drawn && killProcess(drawn.pid, "SIGTERM")) await withTimeout(drawn.exited, "the drawn fixture to exit", 5_000).catch(() => killProcess(drawn.pid));
	if (textEditPid) await stopTextEdit(textEditPid, textEditMonitor);
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(root, { recursive: true, force: true });
}
