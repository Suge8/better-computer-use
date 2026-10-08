#!/usr/bin/env node
// A window on another Space — a full-screen app has a Space of its own — is absent from its
// app's AXWindows, yet it is a root like any other: find-roots lists it (not on screen), its
// @r survives the user switching to its Space and back, observe-ui reads it, and the
// background rungs work on it: an accessibility press, typing by ref, and a click at
// coordinates delivered to the process. The subject is scripts/fixtures/space-window.swift,
// sent to a Space of its own; a stand-in for the user's front app keeps the front and its
// key window throughout, and the user's Space is the one shown at the end.
import assert from "node:assert/strict";
import { execFile as execFileCallback, spawn } from "node:child_process";
import { once } from "node:events";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { createInterface } from "node:readline";
import { promisify } from "node:util";
import { desktop, killProcess, launchKeyHolder, makeTemporaryRoot, repoRoot, request, residentEnvironment, runCli, withTimeout } from "./lib/harness.mjs";

const execFile = promisify(execFileCallback);

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP Spaces (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The Spaces test requires macOS.");

const directory = await makeTemporaryRoot("spaces");
const env = residentEnvironment(path.join(directory, "resident.sock"), 60_000);
const title = `bcu space ${randomUUID().slice(0, 8)}`;
const logPath = path.join(directory, "space.log");
const results = [];
let subject;
let holder;

function check(name, assertion) {
	try {
		assertion();
		results.push([name, true]);
		console.log(`ok ${name}`);
	} catch (error) {
		results.push([name, false]);
		process.exitCode = 1;
		console.error(`FAIL ${name}: ${error.message}`);
	}
}

/** Compiles and starts the fixture; `announced(word)` resolves on the next line saying `word`. */
async function launchSubject() {
	const binary = path.join(directory, "space-window");
	await execFile("xcrun", ["swiftc", path.join(repoRoot, "scripts", "fixtures", "space-window.swift"), "-o", binary], { timeout: 120_000 });
	const child = spawn(binary, [logPath, title], { stdio: ["ignore", "pipe", "ignore"] });
	const exited = once(child, "exit");
	const lines = createInterface({ input: child.stdout });
	const announced = (word) => withTimeout(Promise.race([
		new Promise((resolve) => lines.on("line", function onLine(line) {
			if (line !== word) return;
			lines.off("line", onLine);
			resolve();
		})),
		exited.then(([code, signal]) => { throw new Error(`the Space fixture exited (${signal ?? code})`); }),
	]), `the Space fixture to say ${word}`, 15_000);
	await announced("ready");
	return { pid: child.pid, exited, announced, signal: (name) => process.kill(child.pid, name) };
}

const logged = async () => (await fs.readFile(logPath, "utf8")).split("\n").filter(Boolean);
const bcu = (command, params) => request(command, params, env);
const find = async (params) => (await bcu("find-roots", params)).roots.find((root) => root.title === title);

try {
	subject = await launchSubject();
	holder = await launchKeyHolder(directory);
	const offspace = subject.announced("offspace");
	subject.signal("SIGUSR1");
	await offspace;
	const settled = (await holder.takeFront()).length;
	const front = (await desktop()).front;

	const listed = await find({ pid: subject.pid });
	const broad = await find({});
	check("find-roots lists a window on another Space", () => {
		assert(listed, "the window is not in find-roots --pid");
		assert(broad, "the window is not in the undirected find-roots");
		assert(listed.ref === broad.ref, `the same window got ${listed.ref} and ${broad.ref}`);
		assert(listed.windowId > 0 && listed.kind === "window", JSON.stringify(listed));
		assert(listed.onscreen === false, "a window on a Space the display does not show is not onscreen");
	});
	if (!listed) throw new Error("no root to drive");

	const observed = await bcu("observe-ui", { root: listed.ref });
	const button = observed.nodes.find((node) => node.role === "button" && node.name === "Press me");
	const field = observed.nodes.find((node) => node.role === "textfield");
	check("observe-ui reads it", () => {
		assert(button && field, `the window's controls are not in the view: ${JSON.stringify(observed.nodes)}`);
	});

	const pressed = await bcu("act-ui", { stateId: observed.stateId, actions: [{ action: "press", ref: button.ref }] });
	const pressLog = await logged();
	check("an accessibility press reaches the window", () => {
		assert(pressLog.filter((line) => line === "pressed").length === 1, `log: ${JSON.stringify(pressLog)}`);
		assert(pressed.delivery === "ax", `delivery ${pressed.delivery}`);
	});

	const typed = await bcu("act-ui", { stateId: pressed.stateId, actions: [{ action: "typeText", ref: field.ref, text: "hello" }] });
	const typedLog = await logged();
	check("typing by ref reaches the window", () => {
		assert(typedLog.includes("text hello"), `log: ${JSON.stringify(typedLog)}`);
		assert(typed.outcome !== "didnt", JSON.stringify(typed));
	});

	const frame = listed.frame;
	const padX = frame.x + 120;
	const padY = frame.y + frame.h - 70;
	const clicked = await bcu("act-ui", { stateId: typed.stateId ?? pressed.stateId, actions: [{ action: "click", x: padX, y: padY }] });
	const clickLog = await logged();
	check("a background click at coordinates reaches the window", () => {
		assert(clickLog.some((line) => line.startsWith("click ")), `log: ${JSON.stringify(clickLog)} result ${JSON.stringify(clicked)}`);
	});

	const after = await desktop();
	const lost = (await holder.logged()).length - settled;
	check("the user's front app keeps the front and its key window", () => {
		assert(after.front === front, `the front moved from ${front} to ${after.front}`);
		assert(lost === 0, `the front app lost key ${lost} times`);
	});

	const shown = subject.announced("shown");
	subject.signal("SIGUSR2");
	await shown;
	const present = await find({ pid: subject.pid });
	const hidden = subject.announced("hidden");
	subject.signal("SIGUSR2");
	await hidden;
	const away = await find({ pid: subject.pid });
	check("the root keeps its @r while its Space is shown and when it is not", () => {
		assert(present && away, "the window vanished from find-roots");
		assert(present.ref === listed.ref && away.ref === listed.ref, `refs ${listed.ref} ${present?.ref} ${away?.ref}`);
		assert(present.onscreen === true && away.onscreen === false, `onscreen ${present?.onscreen} ${away?.onscreen}`);
	});
} catch (error) {
	results.push(["live", false]);
	process.exitCode = 1;
	console.error(`FAIL live Spaces ${error.stack}`);
} finally {
	if (subject) {
		killProcess(subject.pid, "SIGTERM");
		await withTimeout(subject.exited, "the Space fixture to exit", 5_000).catch(() => killProcess(subject.pid));
	}
	if (holder) killProcess(holder.pid);
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(directory, { recursive: true, force: true });
}
if (results.some(([, ok]) => !ok)) process.exit(1);
