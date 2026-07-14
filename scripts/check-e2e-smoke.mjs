#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFile as execFileCallback, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP TextEdit smoke (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The TextEdit smoke test requires macOS.");

const execFile = promisify(execFileCallback);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bundle = path.join(root, "dist", "bcu.mjs");
const textEditApp = "/System/Applications/TextEdit.app";
const fixtureDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "bcu-e2e-smoke-"));
const fixtureName = `bcu-smoke-${randomUUID()}.txt`;
const fixturePath = path.join(fixtureDirectory, fixtureName);
const initialText = "bcu smoke fixture\n";
const expectedText = `bcu smoke ${randomUUID()}`;
let createdPid;
let processMonitor;

function flatten(node) {
	return [node, ...(node.children ?? []).flatMap(flatten)];
}

function withTimeout(promise, description, timeoutMs) {
	return new Promise((resolve, reject) => {
		const timeout = setTimeout(() => reject(new Error(`Timed out waiting for ${description}.`)), timeoutMs);
		promise.then(
			(value) => { clearTimeout(timeout); resolve(value); },
			(error) => { clearTimeout(timeout); reject(error); },
		);
	});
}

async function brokerCall(command, args) {
	const { stdout } = await execFile(process.execPath, [bundle, "__request", command, JSON.stringify(args)], {
		cwd: root,
		maxBuffer: 32 * 1024 * 1024,
	});
	return JSON.parse(stdout);
}

function cliCall(args, input) {
	return new Promise((resolve, reject) => {
		const child = spawn(process.execPath, [bundle, ...args], { cwd: root, stdio: ["pipe", "pipe", "pipe"] });
		let stdout = "";
		let stderr = "";
		child.stdout.setEncoding("utf8");
		child.stderr.setEncoding("utf8");
		child.stdout.on("data", (chunk) => { stdout += chunk; });
		child.stderr.on("data", (chunk) => { stderr += chunk; });
		child.on("error", reject);
		child.on("close", (code) => resolve({ code, stdout, stderr }));
		child.stdin.end(input);
	});
}

async function expectCliFailure(stateId, action) {
	const result = await cliCall(["act-ui", "--state", stateId, "-", "--json"], `${JSON.stringify([action])}\n`);
	assert.equal(result.code, 2, `${action.action} invalid payload exited ${result.code}`);
	assert.equal(result.stdout, "", `${action.action} invalid payload wrote stdout`);
	assert.match(result.stderr, /^error invalid_arguments: .+/m);
	assert.match(result.stderr, /^recovery: .+/m);
}

async function expectBrokerFailure(command, args, code) {
	try {
		await brokerCall(command, args);
		assert.fail(`${command} unexpectedly succeeded`);
	} catch (error) {
		assert.notEqual(error.code, 0, `${command} exited zero`);
		assert.equal(error.stdout, "", `${command} wrote a false success to stdout`);
		assert.match(error.stderr, new RegExp(`^error ${code}: .+`, "m"));
		assert.match(error.stderr, /^recovery: .+/m);
	}
}

async function sourceAgentCall(command, args) {
	const clientUrl = pathToFileURL(path.join(root, "src", "client.ts")).href;
	const source = `import { requestBroker } from ${JSON.stringify(clientUrl)}; console.log(JSON.stringify(await requestBroker(process.argv[1], JSON.parse(process.argv[2]))))`;
	const { stdout } = await execFile(process.execPath, ["--input-type=module", "-e", source, command, JSON.stringify(args)], {
		cwd: root,
		maxBuffer: 32 * 1024 * 1024,
	});
	return JSON.parse(stdout);
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

function signalProcess(pid, signal) {
	try {
		process.kill(pid, signal);
		return true;
	} catch (error) {
		if (error?.code === "ESRCH") return false;
		throw error;
	}
}

async function stopTextEdit(pid, monitor) {
	if (!signalProcess(pid, 0)) return;
	monitor ??= await monitorProcess(pid);
	if (!signalProcess(pid, "SIGTERM")) return;
	try {
		await withTimeout(monitor.exited, "the smoke-test TextEdit process to exit", 3_000);
	} catch (error) {
		if (!error.message.startsWith("Timed out waiting for")) throw error;
		if (signalProcess(pid, "SIGKILL")) await withTimeout(monitor.exited, "the smoke-test TextEdit process to stop", 3_000);
	} finally {
		if (monitor.child.exitCode === null && !monitor.child.killed) monitor.child.kill("SIGTERM");
	}
}

try {
	await execFile("npm", ["run", "build", "--silent"], { cwd: root });
	await fs.writeFile(fixturePath, initialText);
	createdPid = await launchTextEdit(fixturePath);
	processMonitor = await monitorProcess(createdPid);
	await waitForAxWindow(createdPid, processMonitor.exited);

	const found = await brokerCall("find-roots", { pid: createdPid, kind: "window" });
	const window = found.details.windows.find((candidate) => candidate.pid === createdPid);
	assert(window, `TextEdit pid ${createdPid} did not expose a root after AXWindowCreated`);
	const observed = await brokerCall("observe-ui", { root: window.windowRef, mode: "semantic", image: "never" });
	assert("capture" in observed.details, "TextEdit observation did not return a desktop state");
	const editor = flatten(observed.details.outline.root).find((node) => node.canSetValue && node.wireRef && !node.pictureOnly);
	assert(editor, "TextEdit observation did not expose an editable semantic node");
	for (const invalidAction of [
		{ action: "click", ref: 123 },
		{ action: "click", ref: editor.ref, button: "banana" },
		{ action: "click", ref: editor.ref, clickCount: "many" },
		{ action: "scroll", ref: editor.ref, scrollY: "abc" },
		{ action: "wait", ms: "soon" },
	]) await expectCliFailure(observed.details.capture.stateId, invalidAction);
	const searched = await sourceAgentCall("search-ui", { stateId: observed.details.capture.stateId, role: "AXTextArea", limit: 50 });
	assert.equal(searched.details?.stateId, observed.details.capture.stateId, "source agent search-ui did not hydrate the shared stateId");
	assert(searched.details?.matches?.length > 0, "source agent search-ui did not return the observed text area");
	const waited = await brokerCall("wait-for", { stateId: observed.details.capture.stateId, role: "AXTextArea", timeoutMs: 1_000 });
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
		brokerCall("act-ui", action),
		brokerCall("act-ui", action),
	]);
	const worked = concurrent.filter((result) => result.status === "fulfilled");
	const stale = concurrent.filter((result) => result.status === "rejected" && result.reason?.stderr?.includes("stale_state:"));
	assert.equal(worked.length, 1, `expected one successful concurrent action, got ${worked.length}`);
	assert.equal(stale.length, 1, `expected one stale_state rejection, got ${stale.length}`);
	const acted = worked[0].value;
	assert("capture" in acted.details, "TextEdit action did not return a desktop state");
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
