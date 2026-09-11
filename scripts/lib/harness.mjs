import { execFile as execFileCallback, spawn } from "node:child_process";
import { once } from "node:events";
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

/** Opens a document in a dedicated TextEdit instance so live tests never touch the user's own windows. */
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

export async function waitForAxWindow(pid, processExited) {
	await runSwiftReadyProbe([
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
	], [pid], "the TextEdit Accessibility window event", { abortedBy: processExited });
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
}
