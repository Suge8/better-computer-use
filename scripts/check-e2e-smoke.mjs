#!/usr/bin/env node
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

function flatten(node) {
	return [node, ...(node.children ?? []).flatMap(flatten)];
}

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
	const window = found.details.windows.find((candidate) => candidate.pid === createdPid);
	assert(window, `TextEdit pid ${createdPid} did not expose a root after AXWindowCreated`);
	const observed = await brokerRequest("observe-ui", { root: window.windowRef, mode: "semantic", image: "never" });
	const editor = flatten(observed.details.outline.root).find((node) => node.canSetValue && node.wireRef && !node.pictureOnly);
	assert(editor, "TextEdit observation did not expose an editable semantic node");
	for (const invalidAction of [
		{ action: "click", ref: 123 },
		{ action: "click", ref: editor.ref, button: "banana" },
		{ action: "click", ref: editor.ref, clickCount: "many" },
		{ action: "scroll", ref: editor.ref, scrollY: "abc" },
		{ action: "wait", ms: "soon" },
	]) await expectCliFailure(observed.details.capture.stateId, invalidAction);
	const searched = await sourceAgentRequest("search-ui", { stateId: observed.details.capture.stateId, role: "AXTextArea", limit: 50 });
	assert.equal(searched.details?.stateId, observed.details.capture.stateId, "source agent search-ui did not hydrate the shared stateId");
	assert(searched.details?.matches?.length > 0, "source agent search-ui did not return the observed text area");
	const waited = await brokerRequest("wait-for", { stateId: observed.details.capture.stateId, role: "AXTextArea", timeoutMs: 1_000 });
	assert.equal(waited.details?.found, true, "wait-for did not find the existing text area");
	assert.doesNotThrow(() => JSON.stringify(waited), "wait-for returned a circular target node");
	await expectBrokerFailure("wait-for", {
		stateId: observed.details.capture.stateId,
		text: "__BCU_NEVER_EXISTS__",
		timeoutMs: 100,
	}, "action_timeout");
	const action = {
		stateId: observed.details.capture.stateId,
		actions: [{ action: "setText", ref: editor.ref, text: expectedText }],
		expect: { value: expectedText, timeoutMs: 5_000 },
		image: "never",
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
	assert.equal(acted.details.execution.outcome, "worked", "TextEdit setText was not verified as worked");
	assert.equal(acted.details.execution.verification?.status, "verified", "TextEdit expect did not observe a new value");
	assert(flatten(acted.details.outline.root).some((node) => node.value === expectedText), "resulting TextEdit outline does not contain the written value");
	await expectBrokerFailure("act-ui", {
		stateId: acted.details.capture.stateId,
		actions: [{ action: "wait", ms: 0 }],
		expect: { text: "__BCU_NEVER_EXISTS__", timeoutMs: 100 },
	}, "action_failed");
	console.log(`PASS TextEdit stdin validation → wait errors → concurrent act → postcondition error in isolated pid ${createdPid}`);
} finally {
	if (createdPid) await stopTextEdit(createdPid, processMonitor);
	await fs.rm(fixtureDirectory, { recursive: true, force: true });
}
