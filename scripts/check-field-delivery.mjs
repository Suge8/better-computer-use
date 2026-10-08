#!/usr/bin/env node
// What a delivery did can differ from what the element's value shows, and bcu must not
// replay a delivery that already landed. The subject is a native window with a chat-style
// field that clears itself on Return, a secure field, and two buttons whose action keeps the
// app from answering Accessibility (a modal alert, and 2.5 s of work on the main thread).
// A stand-in for the user's front app holds the front while the background cells run.
//   - Typed \n, \r and \t reach the field as the real Return and Tab keys; a submit that
//     empties the field is delivered once, in the background and with `--foreground`, and is
//     never judged as having done nothing, which would climb the ladder and send it again.
//   - A secure field's value is a mask, not the typed text, so typing into it is unverified.
//   - A press whose AXPress fails with a timeout is judged on the evidence, not repeated: the
//     slow action runs once, the modal alert opens once.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import {
	residentEnvironment,
	killProcess,
	launchDeliveryFields,
	launchKeyHolder,
	makeTemporaryRoot,
	runCli,
	waitForAxWindow,
	withTimeout,
} from "./lib/harness.mjs";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP field delivery (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The field delivery gate requires macOS.");

const root = await makeTemporaryRoot("field-delivery");
const env = residentEnvironment(path.join(root, "resident.sock"), 60_000);
const title = `bcu fields ${randomUUID().slice(0, 8)}`;
const logPath = path.join(root, "fields.log");
const cells = [];
let fields;
let holder;

async function bcu(args, input) {
	const result = await runCli([...args, "--json"], { input, env });
	if (result.code !== 0) throw new Error(`bcu ${args[0]} exited ${result.code}: ${result.stderr.trim()}`);
	return JSON.parse(result.stdout);
}

async function logged() {
	return (await fs.readFile(logPath, "utf8")).split("\n").filter(Boolean);
}

/** The window's refs, found anew: a ref belongs to the state that minted it. */
async function observed() {
	const found = await bcu(["find-roots", "--pid", String(fields.pid), "--kind", "window"]);
	const window = found.roots.find((candidate) => candidate.title === title);
	assert(window, `bcu found no window titled ${title}`);
	const state = await bcu(["observe-ui", "--root", window.ref]);
	const ref = async (name) => (await bcu(["search-ui", "--state", state.stateId, "--text", name, "--limit", "1"])).matches[0]?.ref;
	return { state, ref };
}

/** One act-ui; the result carries the exit code, since several cells expect failure. */
async function act(actions, flags = []) {
	const { state } = await observed();
	const run = await runCli(["act-ui", "--state", state.stateId, ...flags, "-", "--json"], { input: `${JSON.stringify(actions)}\n`, env });
	return { code: run.code, stderr: run.stderr, result: run.code === 0 ? JSON.parse(run.stdout) : undefined };
}

/** Runs a cell and records every promise it broke instead of stopping at the first. */
async function cell(name, run) {
	const failures = [];
	try {
		const before = (await logged()).length;
		await holder.takeFront();
		await run(failures, before);
	} catch (error) {
		failures.push(error.message);
	}
	cells.push({ name, failures });
	console.log(`${failures.length ? "FAIL" : "PASS"} ${name}${failures.map((failure) => `\n  - ${failure}`).join("")}`);
}

const expectLog = (failures, since, want) => {
	return logged().then((lines) => {
		const got = lines.slice(since);
		if (JSON.stringify(got) !== JSON.stringify(want)) failures.push(`the fixture logged ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
	});
};

/** Waits for the fixture to log `line`, then for its main thread to answer Accessibility again. */
async function untilBusyWorkEnds(line) {
	await withTimeout((async () => {
		while (!(await logged()).includes(line)) await new Promise((resolve) => setTimeout(resolve, 50));
	})(), `the fixture to log ${line}`, 15_000);
	await observed();
}

async function typed(failures, text, flags, { delivery }) {
	const { ref } = await observed();
	const run = await act([{ action: "typeText", ref: await ref("chat"), text }], flags);
	if (run.code !== 0) return failures.push(`typeText exited ${run.code}: ${run.stderr.trim()}`);
	if (run.result.outcome !== "unknown") failures.push(`typing a line break or tab into a field that edits itself was judged ${run.result.outcome}, want unknown`);
	if (run.result.delivery !== delivery) failures.push(`delivered via ${run.result.delivery}, want ${delivery}`);
}

try {
	holder = await launchKeyHolder(root);
	fields = await launchDeliveryFields(root, logPath, title);
	await waitForAxWindow(fields.pid, fields.exited, title);

	await cell("Return typed in the background submits the chat field once", async (failures, since) => {
		await typed(failures, "hello\n", [], { delivery: "pid" });
		await expectLog(failures, since, ["submit hello"]);
	});
	await cell("\\r\\n typed in the background is one Return", async (failures, since) => {
		await typed(failures, "line\r\n", [], { delivery: "pid" });
		await expectLog(failures, since, ["submit line"]);
	});
	await cell("Tab typed in the background is the Tab key", async (failures, since) => {
		await typed(failures, "a\tb\n", [], { delivery: "pid" });
		await expectLog(failures, since, ["tab", "submit ab"]);
	});
	await cell("Return typed with --foreground submits the chat field once", async (failures, since) => {
		await typed(failures, "again\n", ["--foreground"], { delivery: "hid" });
		await expectLog(failures, since, ["submit again"]);
	});
	await cell("typing into a secure field is unverified, and its Return submits once", async (failures, since) => {
		const { ref } = await observed();
		const first = await act([{ action: "typeText", ref: await ref("secret"), text: "abc" }]);
		if (first.code !== 0) return failures.push(`typeText exited ${first.code}: ${first.stderr.trim()}`);
		if (first.result.outcome !== "unknown") failures.push(`typing into a secure field was judged ${first.result.outcome}, want unknown`);
		const second = await act([{ action: "typeText", ref: await ref("secret"), text: "d\n" }]);
		if (second.code !== 0) return failures.push(`typeText exited ${second.code}: ${second.stderr.trim()}`);
		if (second.result.outcome !== "unknown") failures.push(`submitting from a secure field was judged ${second.result.outcome}, want unknown`);
		await expectLog(failures, since, ["secret 4"]);
	});
	await cell("a press that times out is judged on the evidence, not repeated", async (failures, since) => {
		const { ref } = await observed();
		const run = await act([{ action: "press", ref: await ref("slow") }]);
		if (run.code !== 0) failures.push(`press exited ${run.code}: ${run.stderr.trim()}`);
		else if (run.result.delivery !== "ax") failures.push(`delivered via ${run.result.delivery}, want ax`);
		await untilBusyWorkEnds("slow");
		await expectLog(failures, since, ["slow"]);
	});
	await cell("a press that opens a modal alert opens it once and is worked", async (failures, since) => {
		const { ref } = await observed();
		const run = await act([{ action: "press", ref: await ref("dialog") }]);
		if (run.code !== 0) failures.push(`press exited ${run.code}: ${run.stderr.trim()}`);
		else if (run.result.outcome !== "worked") failures.push(`the press was judged ${run.result.outcome}, want worked`);
		const found = await bcu(["find-roots", "--pid", String(fields.pid), "--kind", "dialog"]);
		const alert = found.roots[0];
		if (!alert) return failures.push("no alert is open after the press");
		const state = await bcu(["observe-ui", "--root", alert.ref]);
		const dismissed = await runCli(["act-ui", "--state", state.stateId, "-", "--json"], { input: `${JSON.stringify([{ action: "press", ref: (await bcu(["search-ui", "--state", state.stateId, "--text", "Dismiss", "--limit", "1"])).matches[0].ref }])}\n`, env });
		if (dismissed.code !== 0) failures.push(`dismissing the alert exited ${dismissed.code}: ${dismissed.stderr.trim()}`);
		await expectLog(failures, since, ["dialog", "dismissed"]);
	});
} finally {
	if (fields && killProcess(fields.pid, "SIGTERM")) await withTimeout(fields.exited, "the fixture to exit", 5_000).catch(() => killProcess(fields.pid));
	if (holder && killProcess(holder.pid, "SIGTERM")) await withTimeout(holder.exited, "the key holder to exit", 5_000).catch(() => killProcess(holder.pid));
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(root, { recursive: true, force: true });
}

const failed = cells.filter((entry) => entry.failures.length);
console.log(`${cells.length - failed.length}/${cells.length} field delivery cells passed`);
if (failed.length || cells.length === 0) process.exit(1);
