#!/usr/bin/env node
// Several clients on one app at once, on a real window with an "Add one" button and the
// "count N" label it raises. A selector wait-for that is waiting while another client acts
// (the press that makes its condition hold included) returns found with a state of its own
// instead of failing stale. Selector act-ui calls fired together all succeed and each press
// reaches the app exactly once, counted by the app itself. A ref still belongs to the state
// that made it: once another action stales that state, act-ui --state, wait-for --scope and
// read-text with its refs fail with stale_state.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { killProcess, launchCounter, makeTemporaryRoot, residentEnvironment, runCli, waitForAxWindow, withTimeout } from "./lib/harness.mjs";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP concurrent (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The concurrent test requires macOS.");

const root = await makeTemporaryRoot("concurrent");
const env = residentEnvironment(path.join(root, "resident.sock"), 30_000);
const title = `bcu concurrent ${randomUUID().slice(0, 8)}`;
const logPath = path.join(root, "counter.log");
const press = JSON.stringify([{ action: "press", find: { role: "button", name: "Add one" } }]);
let counter;

async function bcu(args, input) {
	const result = await runCli([...args, "--json"], { input, env });
	if (result.code !== 0) throw new Error(`bcu ${args[0]} exited ${result.code}: ${result.stderr.trim()}`);
	return JSON.parse(result.stdout);
}

async function presses() {
	return (await fs.readFile(logPath, "utf8")).split("\n").filter(Boolean).length;
}

async function expectStale(description, args, input) {
	const result = await runCli(args, { input, env });
	assert.equal(result.code, 3, `${description} exited ${result.code}, not as stale_state: ${result.stderr.trim()}`);
	assert.match(result.stderr, /stale_state:/, `${description} did not report stale_state`);
}

try {
	counter = await launchCounter(root, logPath, title);
	await waitForAxWindow(counter.pid, counter.exited, title);
	const pid = String(counter.pid);

	// A wait that is waiting while another client acts, the last press making its condition hold.
	let settled = false;
	const waiting = runCli(["wait-for", "--pid", pid, "--text", "count 3", "--timeout", "20000", "--json"], { env }).finally(() => { settled = true; });
	await bcu(["act-ui", "--pid", pid, "-"], press);
	await bcu(["act-ui", "--pid", pid, "-"], press);
	assert.equal(settled, false, "wait-for returned before its condition held");
	await bcu(["act-ui", "--pid", pid, "-"], press);
	const waited = await withTimeout(waiting, "wait-for to return", 20_000);
	assert.equal(waited.code, 0, `wait-for failed while another client acted: ${waited.stderr.trim()}`);
	const found = JSON.parse(waited.stdout);
	assert.equal(found.found, true, "wait-for did not report found");
	assert.match(found.stateId ?? "", /^[0-9a-f]{8}$/, "wait-for returned no state of its own");

	// Clients pressing the same button at once: every one succeeds, every press lands once.
	const before = await presses();
	const together = await Promise.all(Array.from({ length: 5 }, () => runCli(["act-ui", "--pid", pid, "-"], { input: press, env })));
	for (const result of together) assert.equal(result.code, 0, `a concurrent act-ui failed: ${result.stderr.trim()}`);
	assert.equal(await presses() - before, 5, "five concurrent presses did not reach the app exactly five times");

	// A ref of a state another action made stale is refused, whatever command carries it.
	const observed = await bcu(["observe-ui", "--pid", pid]);
	const button = observed.nodes.find((node) => node.name === "Add one");
	const label = observed.nodes.find((node) => node.name.startsWith("count "));
	assert(button && label, `the counter's button and label are not in the view: ${JSON.stringify(observed.nodes)}`);
	await bcu(["act-ui", "--state", observed.stateId, "-"], JSON.stringify([{ action: "press", ref: button.ref }]));
	await expectStale("act-ui with a stale ref", ["act-ui", "--state", observed.stateId, "-"], JSON.stringify([{ action: "press", ref: button.ref }]));
	await expectStale("wait-for with a stale scope", ["wait-for", "--state", observed.stateId, "--scope", label.ref, "--text", "count", "--timeout", "2000"]);
	await expectStale("read-text with a stale ref", ["read-text", "--state", observed.stateId, "--ref", label.ref]);

	console.log(`PASS a selector wait-for kept waiting through another client's presses and returned found → five concurrent selector presses all succeeded and landed once each → stale refs refused by act-ui, wait-for --scope and read-text (pid ${counter.pid})`);
} finally {
	if (counter && killProcess(counter.pid, "SIGTERM")) await withTimeout(counter.exited, "the counter to exit", 5_000).catch(() => killProcess(counter.pid));
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(root, { recursive: true, force: true });
}
