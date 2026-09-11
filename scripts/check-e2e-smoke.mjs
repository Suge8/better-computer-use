#!/usr/bin/env node
// The full loop against a real TextEdit window: find, observe, search, reject invalid
// payloads, wait, act with a verified postcondition, and fail honestly when it is not met.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { brokerRequest, buildBundle, launchTextEdit, makeTemporaryRoot, monitorProcess, runCli, sourceAgentRequest, stopTextEdit, waitForAxWindow } from "./lib/harness.mjs";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP TextEdit smoke (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The TextEdit smoke test requires macOS.");

const fixtureDirectory = await makeTemporaryRoot("e2e-smoke");
const fixtureName = `bcu-smoke-${randomUUID()}.txt`;
const fixturePath = path.join(fixtureDirectory, fixtureName);
const initialText = "bcu smoke fixture\n";
const expectedText = `bcu smoke ${randomUUID()}`;
let createdPid;
let processMonitor;

async function expectCliFailure(stateId, action) {
	const result = await runCli(["act-ui", "--state", stateId, "-", "--json"], { input: `${JSON.stringify([action])}\n` });
	assert.equal(result.code, 2, `${action.action} invalid payload exited ${result.code}`);
	assert.equal(result.stdout, "", `${action.action} invalid payload wrote stdout`);
	assert.match(result.stderr, /^error invalid_arguments: .+/m);
	assert.match(result.stderr, /^recovery: .+/m);
}

async function expectBrokerFailure(command, args, code) {
	try {
		await brokerRequest(command, args);
		assert.fail(`${command} unexpectedly succeeded`);
	} catch (error) {
		assert.notEqual(error.code, 0, `${command} exited zero`);
		assert.equal(error.stdout, "", `${command} wrote a false success to stdout`);
		assert.match(error.stderr, new RegExp(`^error ${code}: .+`, "m"));
		assert.match(error.stderr, /^recovery: .+/m);
	}
}

try {
	await buildBundle();
	await fs.writeFile(fixturePath, initialText);
	createdPid = await launchTextEdit(fixturePath);
	processMonitor = await monitorProcess(createdPid);
	await waitForAxWindow(createdPid, processMonitor.exited);

	const found = await brokerRequest("find-roots", { pid: createdPid, kind: "window" });
	const window = found.roots.find((candidate) => candidate.pid === createdPid);
	assert(window, `TextEdit pid ${createdPid} did not expose a root after AXWindowCreated`);
	const observed = await brokerRequest("observe-ui", { root: window.ref, mode: "semantic" });
	assert.equal(observed.root.pid, createdPid, "observe-ui returned another root");
	assert(observed.nodes.every((node) => !/^ax/i.test(node.role)), "observation leaked raw accessibility roles");
	assert.equal(observed.image, undefined, "semantic observation produced an image");
	const editable = await sourceAgentRequest("search-ui", { stateId: observed.stateId, action: "setText", limit: 5 });
	const editor = editable.matches.find((match) => match.caps.includes("setText"));
	assert(editor, "TextEdit observation did not expose an editable element");
	for (const invalidAction of [
		{ action: "click", ref: 123 },
		{ action: "click", ref: editor.ref, button: "banana" },
		{ action: "click", ref: editor.ref, clickCount: "many" },
		{ action: "scroll", ref: editor.ref, scrollY: "abc" },
		{ action: "wait", ms: "soon" },
	]) await expectCliFailure(observed.stateId, invalidAction);
	const searched = await sourceAgentRequest("search-ui", { stateId: observed.stateId, role: "textarea", limit: 50 });
	assert.equal(searched.stateId, observed.stateId, "source agent search-ui did not hydrate the shared stateId");
	assert(searched.matches.length > 0, "source agent search-ui did not return the observed text area");
	const waited = await brokerRequest("wait-for", { stateId: observed.stateId, role: "AXTextArea", timeoutMs: 1_000 });
	assert.equal(waited.found, true, "wait-for did not find the existing text area");
	assert.doesNotThrow(() => JSON.stringify(waited), "wait-for returned a circular result");
	await expectBrokerFailure("wait-for", {
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
		brokerRequest("act-ui", action),
		brokerRequest("act-ui", action),
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
	await expectBrokerFailure("act-ui", {
		stateId: acted.stateId,
		actions: [{ action: "wait", ms: 0 }],
		expect: { text: "__BCU_NEVER_EXISTS__", timeoutMs: 100 },
	}, "action_failed");
	console.log(`PASS TextEdit stdin validation → wait errors → concurrent act → postcondition error in isolated pid ${createdPid}`);
} finally {
	if (createdPid) await stopTextEdit(createdPid, processMonitor);
	await fs.rm(fixtureDirectory, { recursive: true, force: true });
}
