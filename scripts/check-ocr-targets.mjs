#!/usr/bin/env node
// A window with no accessibility content is still operable through the same observe → act
// loop. The subject draws its own Chinese text buttons and exposes nothing to
// Accessibility; a default observation must read them on screen as `ocr` nodes that can be
// pressed, and pressing one must land exactly once, on the rung the delivery ladder allows,
// without claiming a success nothing observable proves. A window that does expose
// accessibility content keeps the capture-free default observation.
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
let drawn;
let textEditPid;
let textEditMonitor;

async function bcu(args, input) {
	const result = await runCli([...args, "--json"], { input, env });
	if (result.code !== 0) throw new Error(`bcu ${args[0]} exited ${result.code}: ${result.stderr.trim()}`);
	return JSON.parse(result.stdout);
}

/** Front application, read by a process that is not bcu. */
async function frontPid() {
	const { stdout } = await execFile("osascript", ["-l", "JavaScript", "-e", "ObjC.import('AppKit'); $.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier"]);
	return Number(stdout.trim());
}

async function frontFinder() {
	await execFile("osascript", ["-l", "JavaScript", "-e", "Application('Finder').activate()"]);
	const { stdout } = await execFile("pgrep", ["-x", "Finder"]);
	assert.equal(await frontPid(), Number(stdout.trim()), "Finder did not come to the front");
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

	// Background clicks are proven on web content only, so a drawn button is pressed in
	// the foreground. Nothing the helper can observe changes, so the press is reported as
	// unknown: a failure that says it may already have landed, never replayed.
	await frontFinder();
	const pressed = await runCli(["act-ui", "--state", observed.stateId, "-", "--json"], { input: `${JSON.stringify([{ action: "press", ref: send.ref }])}\n`, env });
	const log = (await fs.readFile(logPath, "utf8")).split("\n").filter(Boolean);
	assert.deepEqual(log, ["发送"], `the drawn app recorded ${JSON.stringify(log)} instead of exactly one 发送`);
	assert.equal(pressed.code, 9, `pressing 发送 exited ${pressed.code}: ${pressed.stdout}${pressed.stderr}`);
	assert.equal(pressed.stdout, "", "an unproven press wrote a success to stdout");
	assert.match(pressed.stderr, /^error action_failed: .*\bhid\b/m, "the failure does not name the foreground rung it used");
	assert.match(pressed.stderr, /^recovery: .*may already have taken effect/m, "the failure does not warn that the press may have landed");
	assert.equal(await frontPid(), drawn.pid, "the foreground rung did not bring the drawn app forward");

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

	console.log(`PASS drawn window read as ocr nodes → search and inspect agree → foreground press landed once and failed honestly → accessible window stays capture-free (pid ${drawn.pid})`);
} finally {
	if (drawn && killProcess(drawn.pid, "SIGTERM")) await withTimeout(drawn.exited, "the drawn fixture to exit", 5_000).catch(() => killProcess(drawn.pid));
	if (textEditPid) await stopTextEdit(textEditPid, textEditMonitor);
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(root, { recursive: true, force: true });
}
