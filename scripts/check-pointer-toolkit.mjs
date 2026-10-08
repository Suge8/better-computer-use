#!/usr/bin/env node
// A toolkit that reads the pointer from the hardware drops pointer events posted to its pid,
// so a background click on it lands wherever the real pointer is and bcu could only call it
// unverified. A Tk window (tkinter on Tk 8.6 or later) is such a target: a coordinate click
// on its card must reach the card, which only the foreground, moving the real pointer, can
// do. The gate is skipped where no python3 has a working tkinter on Tk 8.6 or later; the
// system python3 (Tk 8.5) takes background clicks, so it does not count.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { createInterface } from "node:readline";
import { residentEnvironment, killProcess, launchKeyHolder, makeTemporaryRoot, repoRoot, runCli, waitForAxWindow, withTimeout } from "./lib/harness.mjs";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP pointer toolkit (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The pointer toolkit gate requires macOS.");

const SKIPPED = Symbol("skipped");
const CANVAS_HEIGHT = 220;
const CANDIDATES = [process.env.BCU_TK_PYTHON, "python3", "python3.13", "python3.12", "python3.11", "/opt/homebrew/Caskroom/miniconda/base/bin/python3"].filter(Boolean);

const root = await makeTemporaryRoot("pointer-toolkit");
const env = residentEnvironment(path.join(root, "resident.sock"), 60_000);
const title = `bcu tk ${randomUUID().slice(0, 8)}`;
const logPath = path.join(root, "tk.log");
let tk;
let holder;

/** Starts the Tk fixture with the first python3 that can run Tk 8.6 or later; undefined when none can. */
async function launchTk() {
	for (const python of CANDIDATES) {
		const child = spawn(python, [path.join(repoRoot, "scripts", "fixtures", "tk-card.py"), logPath, title], { stdio: ["ignore", "pipe", "ignore"] });
		const exited = once(child, "exit").catch(() => []);
		child.on("error", () => {});
		const version = await withTimeout(Promise.race([
			new Promise((resolve) => createInterface({ input: child.stdout }).on("line", (line) => line.startsWith("ready ") && resolve(line.slice("ready ".length)))),
			exited.then(() => ""),
		]), "the Tk window", 8_000).catch(() => "");
		if (Number.parseFloat(version) >= 8.6) return { pid: child.pid, exited };
		if (child.exitCode === null) killProcess(child.pid, "SIGTERM");
		await exited;
	}
	return undefined;
}

async function bcu(args) {
	const result = await runCli([...args, "--json"], { env });
	if (result.code !== 0) throw new Error(`bcu ${args[0]} exited ${result.code}: ${result.stderr.trim()}`);
	return JSON.parse(result.stdout);
}

try {
	holder = await launchKeyHolder(root);
	await fs.writeFile(logPath, "");
	tk = await launchTk();
	if (!tk) {
		console.log("SKIP pointer toolkit (no python3 with a working tkinter on Tk 8.6 or later; set BCU_TK_PYTHON)");
		throw SKIPPED;
	}
	await waitForAxWindow(tk.pid, tk.exited, title);
	await holder.takeFront();

	const found = await bcu(["find-roots", "--pid", String(tk.pid), "--kind", "window"]);
	const window = found.roots.find((candidate) => candidate.title === title);
	assert(window, `bcu found no window titled ${title}`);
	const state = await bcu(["observe-ui", "--root", window.ref]);
	// The canvas fills the window below its title bar; the card is centred at (210, 110) in it.
	const { rect } = (await bcu(["inspect-ui", "--state", state.stateId, "--ref", state.nodes[0].ref])).node;
	const point = { x: rect.x + 210, y: rect.y + rect.h - CANVAS_HEIGHT + 110 };
	const run = await runCli(["act-ui", "--state", state.stateId, "-", "--json"], { input: `${JSON.stringify([{ action: "click", ...point }])}\n`, env });
	assert.equal(run.code, 0, `click exited ${run.code}: ${run.stderr.trim()}`);
	const logged = (await fs.readFile(logPath, "utf8")).split("\n").filter(Boolean);
	assert.deepEqual(logged, ["card"], `the click did not reach the Tk card; the fixture logged ${JSON.stringify(logged)}, bcu reported ${run.stdout.trim()}`);
	assert.equal(JSON.parse(run.stdout).delivery, "hid", "a Tk click can only be delivered through the real pointer");
	console.log("PASS a click on a Tk card reaches it through the foreground");
} catch (error) {
	if (error !== SKIPPED) throw error;
} finally {
	if (tk && killProcess(tk.pid, "SIGTERM")) await withTimeout(tk.exited, "the Tk fixture to exit", 5_000).catch(() => killProcess(tk.pid));
	if (holder && killProcess(holder.pid, "SIGTERM")) await withTimeout(holder.exited, "the key holder to exit", 5_000).catch(() => killProcess(holder.pid));
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(root, { recursive: true, force: true });
}
