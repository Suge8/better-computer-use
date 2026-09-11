#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFile as execFileCallback, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import fs from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { brokerRequest, buildBundle, killProcess, makeTemporaryRoot, runCli, sourceAgentRequest, withTimeout } from "./lib/harness.mjs";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP TextEdit smoke (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The TextEdit smoke test requires macOS.");

const execFile = promisify(execFileCallback);
const textEditApp = "/System/Applications/TextEdit.app";
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

async function launchTextEdit(documentPath) {
	const source = [
		"import AppKit",
		"import Foundation",
		"import Darwin",
		`let appURL = URL(fileURLWithPath: ${JSON.stringify(textEditApp)})`,
		"let documentURL = URL(fileURLWithPath: CommandLine.arguments[1])",
		"let configuration = NSWorkspace.OpenConfiguration()",
		"configuration.createsNewApplicationInstance = true",
		"configuration.activates = false",
		"NSWorkspace.shared.open([documentURL], withApplicationAt: appURL, configuration: configuration) { app, error in",
		"  if let error { fputs(\"\\(error)\\n\", stderr); exit(2) }",
		"  guard let app else { exit(3) }",
		"  print(app.processIdentifier)",
		"  fflush(stdout)",
		"  exit(0)",
		"}",
		"RunLoop.main.run()",
	].join("\n");
	const { stdout } = await execFile("swift", ["-e", source, documentPath], { timeout: 15_000 });
	const pid = Number(stdout.trim());
	if (!Number.isInteger(pid) || pid <= 0) throw new Error(`NSWorkspace returned an invalid TextEdit pid: ${stdout.trim()}`);
	return pid;
}

async function monitorProcess(pid) {
	const source = [
		"import Dispatch",
		"import Darwin",
		"let pid = pid_t(CommandLine.arguments[1])!",
		"let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())",
		"source.setEventHandler { exit(0) }",
		"source.resume()",
		"print(\"ready\")",
		"fflush(stdout)",
		"dispatchMain()",
	].join("\n");
	const child = spawn("swift", ["-e", source, String(pid)], { stdio: ["ignore", "pipe", "pipe"] });
	let stdout = "";
	let stderr = "";
	child.stdout.setEncoding("utf8");
	child.stderr.setEncoding("utf8");
	const ready = new Promise((resolve) => child.stdout.on("data", (chunk) => {
		stdout += chunk;
		if (stdout.includes("ready\n")) resolve();
	}));
	child.stderr.on("data", (chunk) => { stderr += chunk; });
	const exited = once(child, "exit");
	await withTimeout(Promise.race([
		ready,
		exited.then(([code, signal]) => { throw new Error(`Process monitor exited before registration (${signal ?? code}): ${stderr.trim()}`); }),
	]), `the TextEdit ${pid} exit monitor`, 15_000);
	return { child, exited };
}

async function waitForAxWindow(pid, processExited) {
	const monitorSource = [
		"import ApplicationServices",
		"import Foundation",
		"import Darwin",
		"let pid = pid_t(CommandLine.arguments[1])!",
		"let app = AXUIElementCreateApplication(pid)",
		"func ready() { print(\"ready\"); fflush(stdout); exit(0) }",
		"let callback: AXObserverCallback = { _, _, _, _ in ready() }",
		"var observer: AXObserver?",
		"guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { exit(3) }",
		"let added = AXObserverAddNotification(observer, app, \"AXWindowCreated\" as CFString, nil)",
		"guard added == .success || added == .notificationAlreadyRegistered else { exit(4) }",
		"CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)",
		"var value: CFTypeRef?",
		"if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement], !windows.isEmpty { ready() }",
		"DispatchQueue.global().asyncAfter(deadline: .now() + 10) { exit(2) }",
		"CFRunLoopRun()",
	].join("\n");
	const monitor = spawn("swift", ["-e", monitorSource, String(pid)], { stdio: ["ignore", "pipe", "pipe"] });
	let stdout = "";
	let stderr = "";
	monitor.stdout.setEncoding("utf8");
	monitor.stderr.setEncoding("utf8");
	const ready = new Promise((resolve) => {
		monitor.stdout.on("data", (chunk) => {
			stdout += chunk;
			if (stdout.includes("ready\n")) resolve();
		});
	});
	monitor.stderr.on("data", (chunk) => { stderr += chunk; });
	const exited = once(monitor, "exit");
	try {
		await withTimeout(Promise.race([
			ready,
			processExited.then(() => { throw new Error("TextEdit exited before exposing an Accessibility window."); }),
			exited.then(([code, signal]) => { throw new Error(`AX window monitor exited before ready (${signal ?? code}): ${stderr.trim()}`); }),
		]), "the TextEdit Accessibility window event", 15_000);
		const [code, signal] = await exited;
		if (code !== 0 || signal) throw new Error(`AX window monitor failed (${signal ?? code}): ${stderr.trim()}`);
	} finally {
		if (monitor.exitCode === null && !monitor.killed) monitor.kill("SIGTERM");
	}
}

async function stopTextEdit(pid, monitor) {
	if (!killProcess(pid, 0)) return;
	monitor ??= await monitorProcess(pid);
	if (!killProcess(pid, "SIGTERM")) return;
	try {
		await withTimeout(monitor.exited, "the smoke-test TextEdit process to exit", 3_000);
	} catch (error) {
		if (!error.message.startsWith("Timed out waiting for")) throw error;
		if (killProcess(pid, "SIGKILL")) await withTimeout(monitor.exited, "the smoke-test TextEdit process to stop", 3_000);
	} finally {
		if (monitor.child.exitCode === null && !monitor.child.killed) monitor.child.kill("SIGTERM");
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
