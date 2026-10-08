#!/usr/bin/env node
// Writing a text value onto a Finder file name changes only what is shown: in a list view the
// name cell (it carries AXFilename and a file AXURL and is not focused), and in a Get Info
// window the Name & Extension field. Finder keeps the file's old name on disk, and the value
// reads back as the new one, so bcu must not report a rename it did not make. The gate
// renames a throwaway file in /tmp, never a user file: setText on each field is refused
// with action_failed and a recovery that names the keyboard route, the file keeps its name,
// and that route does rename it.
import assert from "node:assert/strict";
import { execFile as execFileCallback } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { residentEnvironment, makeTemporaryRoot, runCli } from "./lib/harness.mjs";

const execFile = promisify(execFileCallback);

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP Finder rename (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The Finder rename gate requires macOS.");

const root = await makeTemporaryRoot("finder-rename");
const files = await makeTemporaryRoot("finder-files");
const env = residentEnvironment(path.join(root, "resident.sock"), 60_000);
const folderTitle = path.basename(files);
let windowsBefore;

async function bcu(args, input) {
	const result = await runCli([...args, "--json"], { input, env });
	if (result.code !== 0) throw new Error(`bcu ${args[0]} exited ${result.code}: ${result.stderr.trim()}`);
	return JSON.parse(result.stdout);
}

async function finder(script) {
	return (await execFile("osascript", ["-e", `tell application "Finder"\n${script}\nend tell`])).stdout.trim();
}

const names = async () => (await fs.readdir(files)).sort();

async function windows() {
	return (await bcu(["find-roots", "--app", "Finder", "--kind", "window"])).roots;
}

/** The Get Info window: any Finder window but the folder's own and the desktop's. */
async function infoWindow() {
	const found = (await windows()).find((candidate) => candidate.title !== folderTitle && candidate.title !== "(untitled)");
	assert(found, "Finder shows no Get Info window");
	return found.ref;
}

async function folderWindow() {
	const found = (await windows()).find((candidate) => candidate.title === folderTitle);
	assert(found, `Finder shows no window titled ${folderTitle}`);
	return found.ref;
}

/** The text field holding `value` in a fresh observation of `rootRef`. */
async function fieldWith(rootRef, value, image) {
	const state = await bcu(["observe-ui", "--root", rootRef, ...(image ? ["--image", "always"] : [])]);
	const found = await bcu(["search-ui", "--state", state.stateId, "--role", "textfield", "--limit", "10"]);
	const match = found.matches.find((candidate) => candidate.value === value);
	assert(match, `no text field holds ${value}: ${JSON.stringify(found.matches.map((candidate) => [candidate.name, candidate.value]))}`);
	return { state, ref: match.ref };
}

/** setText must be refused with the keyboard route, and the file must keep its name. */
async function assertRefused(rootRef, current) {
	const { state, ref } = await fieldWith(rootRef, current);
	const run = await runCli(["act-ui", "--state", state.stateId, "-", "--json"], { input: `${JSON.stringify([{ action: "setText", ref, text: "renamed.txt" }])}\n`, env });
	assert.equal(run.code, 9, `setText on the Finder name ${current} exited ${run.code}, want 9 (action_failed): ${run.stdout.trim()}`);
	assert.match(run.stderr, /error action_failed/);
	assert.match(run.stderr, /Return/, "the recovery names no keyboard route");
	assert.deepEqual(await names(), [current], "the refused write still changed the file");
}

/** Runs the keyboard route the recovery names; `select` leads to the name being edited. */
async function renameByKeyboard(rootRef, current, next, select) {
	const { state, ref } = await fieldWith(rootRef, current, true);
	const actions = [{ action: "click", ref }, ...select, { action: "keypress", keys: ["cmd", "a"] }, { action: "typeText", text: next }, { action: "keypress", keys: ["Return"] }];
	const run = await runCli(["act-ui", "--state", state.stateId, "--foreground", "-", "--json"], { input: `${JSON.stringify(actions)}\n`, env });
	assert.equal(run.code, 0, `the keyboard route exited ${run.code}: ${run.stderr.trim()}`);
}

try {
	await fs.writeFile(path.join(files, "alpha.txt"), "a");
	windowsBefore = await finder("return id of every window");
	await finder(`set w to make new Finder window to (POSIX file ${JSON.stringify(files)} as alias)\nset current view of w to list view`);

	await assertRefused(await folderWindow(), "alpha.txt");
	await renameByKeyboard(await folderWindow(), "alpha.txt", "beta.txt", [{ action: "keypress", keys: ["Return"] }, { action: "wait", ms: 400 }]);
	assert.deepEqual(await names(), ["beta.txt"], "the keyboard route did not rename the file in the list view");
	console.log("PASS the list view name cell refuses a value write; Return, cmd+a, the name, Return rename");

	await finder(`open information window of (POSIX file ${JSON.stringify(path.join(files, "beta.txt"))} as alias)`);
	await assertRefused(await infoWindow(), "beta.txt");
	await renameByKeyboard(await infoWindow(), "beta.txt", "gamma.txt", []);
	assert.deepEqual(await names(), ["gamma.txt"], "the keyboard route did not rename the file in Get Info");
	console.log("PASS the Get Info name field refuses a value write; focusing it, cmd+a, the name, Return rename");
} finally {
	// Only the windows this run opened; the user's own stay.
	if (windowsBefore !== undefined) {
		const kept = windowsBefore.split(", ").map(Number).filter(Number.isInteger);
		await finder(`set windowIds to id of every window\nrepeat with entry in windowIds\nset windowId to contents of entry\nif {${kept.join(", ")}} does not contain windowId then close (first window whose id is windowId)\nend repeat`);
	}
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(root, { recursive: true, force: true });
	await fs.rm(files, { recursive: true, force: true });
}
