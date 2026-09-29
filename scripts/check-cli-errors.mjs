#!/usr/bin/env node
// The CLI failure surface, against the bcu executable built from this checkout with no
// resident able to start: every command documents itself, malformed arguments and action
// payloads are rejected as invalid_arguments before anything is started or connected, a
// valid payload gets as far as starting the resident, a resident that cannot start is
// reported as resident_unavailable, and setup refuses a terminal nobody can answer. Failures
// write nothing to stdout and name their code and recovery on stderr.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";
import { makeTemporaryRoot, runCli, useBuiltCli } from "./lib/harness.mjs";

await useBuiltCli();
const root = await makeTemporaryRoot("cli-errors");
const socketDirectory = path.join(root, "run");
const missingApp = path.join(root, "missing", "bcu.app");
const env = { ...process.env, BCU_SOCKET_PATH: path.join(socketDirectory, "resident.sock"), BCU_APP_PATH: missingApp };

const run = (args, input = "") => runCli(args, { input, env });

function assertFailure(result, code, label) {
	assert.notEqual(result.code, 0, `${label} unexpectedly exited zero`);
	assert.equal(result.stdout, "", `${label} wrote to stdout on failure`);
	const lines = result.stderr.trim().split("\n");
	assert.match(lines[0] ?? "", new RegExp(`^error ${code}: .+`), `${label} did not fail with ${code}: ${result.stderr}`);
	assert.match(lines[1] ?? "", /^recovery: .+/, `${label} omitted recovery guidance`);
}

const act = (actions) => run(["act-ui", "--state", "abcd1234", "-"], JSON.stringify(actions));

try {
	const help = await run(["--help"]);
	assert.equal(help.code, 0, "bcu --help failed");
	const publicCommands = [
		"find-roots", "observe-ui", "search-ui", "expand-ui", "inspect-ui", "act-ui", "read-text", "wait-for",
		"status", "doctor", "setup", "stop",
	];
	for (const command of publicCommands) assert(help.stdout.includes(command), `bcu --help omitted ${command}`);
	assert(!/browser/i.test(help.stdout), "bcu --help advertises browser commands");
	for (const command of publicCommands) {
		const commandHelp = await run([command, "--help"]);
		assert.equal(commandHelp.code, 0, `bcu ${command} --help failed`);
		assert(commandHelp.stdout.startsWith(`bcu ${command}`), `bcu ${command} --help does not describe ${command}`);
		assert(commandHelp.stdout.includes("--json"), `bcu ${command} --help omits --json`);
	}

	assertFailure(await run(["read-text", "--state", "abcd1234"]), "invalid_arguments", "read-text without --ref");
	assertFailure(await run(["expand-ui", "--state", "abcd1234"]), "invalid_arguments", "expand-ui without --ref");
	assertFailure(await run(["find-roots", "--pid", "abc"]), "invalid_arguments", "a non-numeric --pid");
	assertFailure(await run(["no-such-command"]), "invalid_arguments", "an unknown command");
	assertFailure(await run(["act-ui", "--state", "abcd1234", "-"], "not-json\n"), "invalid_arguments", "act-ui with a non-JSON payload");
	const invalidActions = [
		["numeric ref", { action: "click", ref: 123 }],
		["empty ref", { action: "click", ref: "" }],
		["invalid button", { action: "click", ref: "@e1", button: "banana" }],
		["invalid clickCount type", { action: "click", ref: "@e1", clickCount: "many" }],
		["invalid clickCount range", { action: "click", ref: "@e1", clickCount: 4 }],
		["ignored doubleClick count", { action: "doubleClick", ref: "@e1", clickCount: 2 }],
		["invalid scrollY", { action: "scroll", ref: "@e1", scrollY: "abc" }],
		["invalid scroll range", { action: "scroll", ref: "@e1", scrollX: 10_001 }],
		["invalid wait ms", { action: "wait", ms: "soon" }],
		["invalid wait range", { action: "wait", ms: 60_001 }],
		["partial coordinates", { action: "click", x: 10 }],
		["mixed targets", { action: "click", ref: "@e1", x: 10, y: 10 }],
		["missing keys", { action: "keypress" }],
		["invalid keys", { action: "keypress", ref: "@e1", keys: [1] }],
		["orphaned typing", { action: "typeText", text: "orphaned" }],
		["missing text", { action: "setText", ref: "@e1" }],
		["short drag", { action: "drag", path: [{ x: 1, y: 1 }] }],
		["invalid drag point", { action: "drag", path: [{ x: 1, y: 1 }, { x: "bad", y: 2 }] }],
		["unsupported field", { action: "wait", button: "left" }],
		["unknown field", { action: "click", ref: "@e1", extra: true }],
		["missing target", { action: "click" }],
	];
	for (const [label, action] of invalidActions) assertFailure(await act([action]), "invalid_arguments", label);
	assertFailure(await act([]), "invalid_arguments", "an empty action array");
	assertFailure(await act(Array.from({ length: 21 }, () => ({ action: "wait" }))), "invalid_arguments", "21 actions");
	assert(!existsSync(socketDirectory), "a rejected command reached for the resident");

	// A valid payload passes validation and only then fails, on the resident that cannot start.
	for (const actions of [
		[{ action: "click", ref: "@e1" }],
		[{ action: "click", x: 10, y: 10, button: "middle", clickCount: 3 }],
		[{ action: "wait", ms: 0 }],
		[{ action: "drag", path: [[1, 1], { x: 2, y: 2 }] }],
		[{ action: "setText", ref: "@e1", text: "" }],
		[{ action: "click", x: 10, y: 10 }, { action: "typeText", text: "focused" }],
		[{ action: "press", ref: "@e1" }, { action: "keypress", keys: ["return"] }],
	]) assertFailure(await act(actions), "resident_unavailable", `valid actions ${JSON.stringify(actions)}`);
	const unstartable = await run(["find-roots"]);
	assertFailure(unstartable, "resident_unavailable", "a command whose resident cannot start");
	assert(unstartable.stderr.includes(missingApp), `the failure does not name the missing app: ${unstartable.stderr}`);

	assertFailure(await run(["setup"]), "permission_missing", "setup without a terminal");
	console.log(`CLI error checks passed (${publicCommands.length} help screens, ${invalidActions.length + 7} rejected payloads, unstartable resident, non-interactive setup).`);
} finally {
	await fs.rm(root, { recursive: true, force: true });
}
