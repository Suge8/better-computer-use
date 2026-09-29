import { execFile as execFileCallback, spawn } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { npmInvocation } from "../npm-invocation.mjs";

const execFile = promisify(execFileCallback);
export const TEXT_EDIT_APP = "/System/Applications/TextEdit.app";

export const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
export const bundlePath = path.join(repoRoot, "dist", "bcu.mjs");

/** Builds the CLI bundle the harness invokes. */
export async function buildBundle() {
	const [npm, npmArgs] = npmInvocation(["run", "build", "--silent"]);
	await execFile(npm, npmArgs, { cwd: repoRoot });
}

export async function makeTemporaryRoot(label) {
	return await fs.mkdtemp(path.join(os.tmpdir(), `bcu-${label}-`));
}

/** Isolates a test broker on its own socket so it never touches the user's broker. */
export function brokerEnvironment(socketPath, idleMs) {
	return { ...process.env, BCU_BROKER_SOCKET_PATH: socketPath, BCU_IDLE_MS: String(idleMs) };
}

export function rejectAfter(description, milliseconds) {
	return new Promise((_, reject) => {
		const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${description}.`)), milliseconds);
		timer.unref?.();
	});
}

export function withTimeout(promise, description, milliseconds) {
	return Promise.race([promise, rejectAfter(description, milliseconds)]);
}

/** Starts a broker in-process-per-test and resolves once it signals readiness on fd 3. */
export function spawnBroker(env) {
	const broker = spawn(process.execPath, [bundlePath, "__serve"], {
		cwd: repoRoot,
		env,
		stdio: ["ignore", "ignore", "pipe", "pipe"],
	});
	let stderr = "";
	broker.stderr.setEncoding("utf8");
	broker.stderr.on("data", (chunk) => { stderr += chunk; });
	return { process: broker, ready: broker.stdio[3], stderr: () => stderr };
}

/** One broker command through the CLI's internal request path. */
export async function brokerRequest(command, args = {}, env = process.env) {
	const { stdout } = await execFile(process.execPath, [bundlePath, "__request", command, JSON.stringify(args)], {
		cwd: repoRoot,
		env,
		maxBuffer: 32 * 1024 * 1024,
	});
	return JSON.parse(stdout);
}

/** One broker command issued the way an agent library would: through src/client.ts. */
export async function sourceAgentRequest(command, args = {}, env = process.env) {
	const clientUrl = pathToFileURL(path.join(repoRoot, "src", "client.ts")).href;
	const source = `import { requestBroker } from ${JSON.stringify(clientUrl)}; console.log(JSON.stringify(await requestBroker(process.argv[1], JSON.parse(process.argv[2]))))`;
	const { stdout } = await execFile(process.execPath, ["--input-type=module", "-e", source, command, JSON.stringify(args)], {
		cwd: repoRoot,
		env,
		maxBuffer: 32 * 1024 * 1024,
	});
	return JSON.parse(stdout);
}

/** Runs the public CLI and captures its exit code and streams. */
export function runCli(args, { input = "", env = process.env } = {}) {
	return new Promise((resolve, reject) => {
		const child = spawn(process.execPath, [bundlePath, ...args], { cwd: repoRoot, env, stdio: ["pipe", "pipe", "pipe"] });
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

export function killProcess(pid, signal = "SIGKILL") {
	try {
		process.kill(pid, signal);
		return true;
	} catch (error) {
		if (error?.code === "ESRCH") return false;
		throw error;
	}
}

/**
 * Runs a Swift snippet that prints `ready` once its subject is observable, then exits.
 * Live desktop waits are driven by Accessibility notifications rather than polling.
 */
export async function runSwiftReadyProbe(lines, args, description, { timeoutMs = 15_000, abortedBy } = {}) {
	const child = spawn("swift", ["-e", lines.join("\n"), ...args.map(String)], { stdio: ["ignore", "pipe", "pipe"] });
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
	try {
		await withTimeout(Promise.race([
			ready,
			...(abortedBy ? [abortedBy.then(() => { throw new Error(`The subject exited before ${description}.`); })] : []),
			exited.then(([code, signal]) => { throw new Error(`${description} probe exited before ready (${signal ?? code}): ${stderr.trim()}`); }),
		]), description, timeoutMs);
		const [code, signal] = await exited;
		if (code !== 0 || signal) throw new Error(`${description} probe failed (${signal ?? code}): ${stderr.trim()}`);
		return stdout;
	} finally {
		if (child.exitCode === null && !child.killed) child.kill("SIGTERM");
	}
}

/**
 * Compiles scripts/fixtures/<name>.swift and runs it until it prints `ready`. `nextReady`
 * resolves on the following `ready`, for fixtures that announce it more than once.
 */
async function launchSwiftFixture(directory, name, args, waiting) {
	const binary = path.join(directory, name);
	await execFile("xcrun", ["swiftc", path.join(repoRoot, "scripts", "fixtures", `${name}.swift`), "-o", binary], { timeout: 120_000 });
	const child = spawn(binary, args, { stdio: ["ignore", "pipe", "ignore"] });
	const exited = once(child, "exit");
	const lines = createInterface({ input: child.stdout });
	const nextReady = (description) => withTimeout(Promise.race([
		new Promise((resolve) => lines.on("line", function onLine(line) {
			if (line !== "ready") return;
			lines.off("line", onLine);
			resolve();
		})),
		exited.then(([code, signal]) => { throw new Error(`the ${name} fixture exited (${signal ?? code})`); }),
	]), description, 15_000);
	await nextReady(waiting);
	return { pid: child.pid, exited, nextReady };
}

/** Starts scripts/fixtures/drawn-buttons.swift, a window with no accessible content. */
export async function launchDrawnButtons(directory, logPath, title) {
	const { pid, exited } = await launchSwiftFixture(directory, "drawn-buttons", [logPath, title], "the drawn fixture window");
	return { pid, exited };
}

/** Starts scripts/fixtures/drawn-input.swift, a self-drawn text input with no accessible content. */
export async function launchDrawnInput(directory, logPath, title) {
	const { pid, exited } = await launchSwiftFixture(directory, "drawn-input", [logPath, title], "the drawn input window");
	return { pid, exited };
}

/** Front application and real pointer, read by a process that is not bcu. */
export async function desktop() {
	const { stdout } = await execFile("osascript", ["-l", "JavaScript", "-e", [
		"ObjC.import('AppKit')",
		"const m = $.NSEvent.mouseLocation",
		"JSON.stringify({ front: $.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier, x: m.x, y: m.y })",
	].join(";")]);
	return JSON.parse(stdout);
}

const INPUT_SOURCE_TOOL = [
	"import Carbon",
	"func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? { TISGetInputSourceProperty(source, key).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() } }",
	"let wanted = CommandLine.arguments.dropFirst().first",
	"if let wanted {",
	"  let enabled = TISCreateInputSourceList([kTISPropertyInputSourceID as String: wanted] as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] ?? []",
	"  guard let source = enabled.first else { print(\"{}\"); exit(0) }",
	"  guard TISSelectInputSource(source) == noErr else { exit(2) }",
	"}",
	"let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()",
	"let type = property(current, kTISPropertyInputSourceType) as? String ?? \"\"",
	"let languages = property(current, kTISPropertyInputSourceLanguages) as? [String] ?? []",
	"let composes = type != (kTISTypeKeyboardLayout as String) && languages.first.map { [\"zh\", \"ja\", \"ko\"].contains(String($0.prefix(2))) } == true",
	"let id = property(current, kTISPropertyInputSourceID) as? String ?? \"\"",
	"print(\"{\\\"id\\\":\\\"\\(id)\\\",\\\"cjk\\\":\\(composes)}\")",
].join("\n");

/**
 * Selects the enabled keyboard input source `id` for the whole session and returns the one
 * now current as `{id, cjk}`, `cjk` telling whether it is a Chinese, Japanese or Korean
 * input method that composes keys into other text. `{}` means `id` is not enabled on this
 * Mac. Without `id` it only reads the current one.
 */
export async function selectInputSource(id) {
	const { stdout } = await execFile("swift", ["-e", INPUT_SOURCE_TOOL, ...(id ? [id] : [])], { timeout: 60_000 });
	return JSON.parse(stdout);
}

/**
 * Starts scripts/fixtures/key-holder.swift, a stand-in for the user's front app that logs
 * every loss of its key window or activation. `takeFront` hands it the front again and
 * returns the lines it has logged so far.
 */
export async function launchKeyHolder(directory) {
	const logPath = path.join(directory, "key-holder.log");
	const holder = await launchSwiftFixture(directory, "key-holder", [logPath], "the key holder to take the front");
	const logged = async () => (await fs.readFile(logPath, "utf8")).split("\n").filter(Boolean);
	return {
		pid: holder.pid,
		exited: holder.exited,
		logged,
		async takeFront() {
			const ready = holder.nextReady("the key holder to take the front back");
			process.kill(holder.pid, "SIGUSR1");
			await ready;
			return await logged();
		},
	};
}

/**
 * Opens a document in a dedicated TextEdit instance so live tests never touch the user's own
 * windows, and without restoring the windows of earlier sessions.
 */
export async function launchTextEdit(documentPath) {
	const source = [
		"import AppKit",
		"import Foundation",
		"import Darwin",
		`let appURL = URL(fileURLWithPath: ${JSON.stringify(TEXT_EDIT_APP)})`,
		"let documentURL = URL(fileURLWithPath: CommandLine.arguments[1])",
		"let configuration = NSWorkspace.OpenConfiguration()",
		"configuration.createsNewApplicationInstance = true",
		"configuration.activates = false",
		// Restored windows from earlier sessions would crowd and replace the test's own document.
		// Automatic capitalization would rewrite typed text the way it would the user's.
		"configuration.arguments = [\"-ApplePersistenceIgnoreState\", \"YES\", \"-NSAutomaticCapitalizationEnabled\", \"NO\"]",
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

/** Resolves when the process exits, so tests can fail fast instead of waiting out a timeout. */
export async function monitorProcess(pid) {
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

/** Resolves once the window whose title starts with `titlePrefix` is exposed to Accessibility. */
export async function waitForAxWindow(pid, processExited, titlePrefix = "") {
	await runSwiftReadyProbe([
		"import ApplicationServices",
		"import Foundation",
		"import Darwin",
		"let pid = pid_t(CommandLine.arguments[1])!",
		"let titlePrefix = CommandLine.arguments[2]",
		"let app = AXUIElementCreateApplication(pid)",
		"func ready() { print(\"ready\"); fflush(stdout); exit(0) }",
		"func titles() -> [String] {",
		"  var value: CFTypeRef?",
		"  guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] else { return [] }",
		"  return windows.map { window in",
		"    var title: CFTypeRef?",
		"    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)",
		"    return (title as? String) ?? \"\"",
		"  }",
		"}",
		"func readyIfPresent() { if titles().contains(where: { $0.hasPrefix(titlePrefix) }) { ready() } }",
		"let callback: AXObserverCallback = { _, _, _, _ in readyIfPresent() }",
		"var observer: AXObserver?",
		"guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { exit(3) }",
		"let added = AXObserverAddNotification(observer, app, \"AXWindowCreated\" as CFString, nil)",
		"guard added == .success || added == .notificationAlreadyRegistered else { exit(4) }",
		"CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)",
		"readyIfPresent()",
		"DispatchQueue.global().asyncAfter(deadline: .now() + 10) { fputs(\"no window titled \\(titlePrefix); have \\(titles())\\n\", stderr); exit(1) }",
		"CFRunLoopRun()",
	], [pid, titlePrefix], "the TextEdit Accessibility window event", { abortedBy: processExited });
}

/**
 * When the front app quits, macOS hands the front to another app a moment later. A test
 * that starts before that lands can have its own activation undone, closing the menus it
 * opened, so this resolves once the front belongs to a live app other than `pid`.
 */
async function waitForFrontToLeave(pid) {
	await runSwiftReadyProbe([
		"import AppKit",
		"import Darwin",
		"let pid = pid_t(CommandLine.arguments[1])!",
		"func ready() { print(\"ready\"); fflush(stdout); exit(0) }",
		"func settled() -> Bool { guard let front = NSWorkspace.shared.frontmostApplication else { return false }; return front.processIdentifier != pid && !front.isTerminated }",
		"NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in if settled() { ready() } }",
		"if settled() { ready() }",
		"RunLoop.main.run()",
	], [pid], "the front to move off the stopped TextEdit", { timeoutMs: 5_000 });
}

export async function stopTextEdit(pid, monitor) {
	if (!killProcess(pid, 0)) return;
	monitor ??= await monitorProcess(pid);
	if (!killProcess(pid, "SIGTERM")) return;
	try {
		await withTimeout(monitor.exited, "the live-test TextEdit process to exit", 3_000);
	} catch (error) {
		if (!error.message.startsWith("Timed out waiting for")) throw error;
		if (killProcess(pid, "SIGKILL")) await withTimeout(monitor.exited, "the live-test TextEdit process to stop", 3_000);
	} finally {
		if (monitor.child.exitCode === null && !monitor.child.killed) monitor.child.kill("SIGTERM");
	}
	await waitForFrontToLeave(pid);
}
