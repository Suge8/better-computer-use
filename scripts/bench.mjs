#!/usr/bin/env node

import { execFile as execFileCallback, spawn } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import { watch } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFile = promisify(execFileCallback);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bundle = path.join(root, "dist", "bcu.mjs");
const socketPath = process.env.BCU_SOCKET_PATH ?? path.join(os.homedir(), "Library/Caches/bcu/bridge.sock");
const helperBundleId = "com.sugeh.bcu";
const protocolVersion = 6;
let requestNumber = 0;

function callHelper(command, args = {}, timeoutMs = 20_000) {
	return new Promise((resolve, reject) => {
		const socket = net.createConnection(socketPath);
		let buffer = "";
		let settled = false;
		const finish = (error, result) => {
			if (settled) return;
			settled = true;
			socket.destroy();
			if (error) reject(error);
			else resolve(result);
		};
		socket.setEncoding("utf8");
		socket.setTimeout(timeoutMs, () => finish(new Error(`Timed out calling ${command}.`)));
		socket.on("connect", () => {
			requestNumber += 1;
			socket.write(`${JSON.stringify({ id: `bench-${requestNumber}`, cmd: command, ...args })}\n`);
		});
		socket.on("data", (chunk) => {
			buffer += chunk;
			const newline = buffer.indexOf("\n");
			if (newline < 0) return;
			const response = JSON.parse(buffer.slice(0, newline));
			if (!response.ok) {
				const error = new Error(response.error?.message ?? `${command} failed.`);
				error.code = response.error?.code;
				finish(error);
				return;
			}
			finish(undefined, response.result);
		});
		socket.on("error", (error) => finish(error));
	});
}

async function currentDiagnostics() {
	try {
		return await callHelper("diagnostics", {}, 2_000);
	} catch (error) {
		if (["ENOENT", "ECONNREFUSED"].includes(error.code)) return undefined;
		throw error;
	}
}

async function stopHelper(diagnostics) {
	if (!diagnostics) return;
	const monitorSource = [
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
	const monitor = spawn("swift", ["-e", monitorSource, String(diagnostics.pid)], { stdio: ["ignore", "pipe", "pipe"] });
	const exited = once(monitor, "exit");
	let stderr = "";
	monitor.stderr.setEncoding("utf8");
	monitor.stderr.on("data", (chunk) => { stderr += chunk; });
	await new Promise((resolve, reject) => {
		let stdout = "";
		monitor.stdout.setEncoding("utf8");
		monitor.stdout.on("data", (chunk) => {
			stdout += chunk;
			if (stdout.includes("ready\n")) resolve();
		});
		monitor.once("error", reject);
		monitor.once("exit", (code) => reject(new Error(`Process monitor exited before registration (${code}): ${stderr.trim()}`)));
	});
	await callHelper("shutdown");
	const [code] = await exited;
	if (code !== 0) throw new Error(`Process monitor failed (${code}): ${stderr.trim()}`);
}

async function coldStartHelper() {
	await fs.mkdir(path.dirname(socketPath), { recursive: true });
	let finish;
	let inFlight = false;
	let retryRequested = false;
	const ready = new Promise((resolve, reject) => { finish = { resolve, reject }; });
	const watcher = watch(path.dirname(socketPath));
	const startedAt = performance.now();
	let settled = false;
	const timeout = setTimeout(() => {
		if (!settled) finish.reject(new Error("Timed out waiting for the cold helper start."));
	}, 15_000);
	const probe = async () => {
		if (settled) return;
		if (inFlight) {
			retryRequested = true;
			return;
		}
		inFlight = true;
		try {
			const diagnostics = await callHelper("diagnostics", {}, 2_000);
			if (diagnostics.protocolVersion !== protocolVersion) throw new Error(`Expected protocol ${protocolVersion}, got ${diagnostics.protocolVersion}.`);
			settled = true;
			finish.resolve({ diagnostics, elapsedMs: performance.now() - startedAt });
		} catch (error) {
			if (!["ENOENT", "ECONNREFUSED"].includes(error.code)) finish.reject(error);
		} finally {
			inFlight = false;
			if (retryRequested && !settled) {
				retryRequested = false;
				void probe();
			}
		}
	};
	watcher.on("change", (_event, filename) => {
		if (String(filename) === path.basename(socketPath)) void probe();
	});
	watcher.on("error", (error) => finish.reject(error));
	try {
		await execFile("open", ["-n", "-g", "-b", helperBundleId, "--args", "serve", "--socket", socketPath]);
		void probe();
		return await ready;
	} finally {
		clearTimeout(timeout);
		watcher.close();
	}
}

function rounded(value) {
	return Math.round(value * 100) / 100;
}

function median(values) {
	const sorted = [...values].sort((left, right) => left - right);
	const middle = sorted.length / 2;
	return sorted.length % 2 ? sorted[Math.floor(middle)] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function brokerConnection(socketPath) {
	return new Promise((resolve, reject) => {
		const socket = net.createConnection(socketPath);
		const pending = new Map();
		let buffer = "";
		const fail = (error) => {
			for (const waiter of pending.values()) waiter.reject(error);
			pending.clear();
		};
		socket.setEncoding("utf8");
		socket.on("data", (chunk) => {
			buffer += chunk;
			for (;;) {
				const newline = buffer.indexOf("\n");
				if (newline < 0) return;
				const response = JSON.parse(buffer.slice(0, newline));
				buffer = buffer.slice(newline + 1);
				const waiter = pending.get(response.id);
				if (!waiter) continue;
				pending.delete(response.id);
				if (response.ok) waiter.resolve(response.result);
				else waiter.reject(Object.assign(new Error(response.error?.message ?? "Broker command failed."), { code: response.error?.code }));
			}
		});
		socket.on("error", fail);
		socket.on("close", () => fail(new Error("Broker connection closed.")));
		socket.once("connect", () => resolve({
			call(command, args = {}) {
				return new Promise((resolve, reject) => {
					const id = `bench-broker-${++requestNumber}`;
					pending.set(id, { resolve, reject });
					socket.write(`${JSON.stringify({ id, cmd: command, args })}\n`);
				});
			},
			close() { socket.end(); },
		}));
		socket.once("error", reject);
	});
}

async function measureBrokerDiagnostics() {
	await execFile("npm", ["run", "build", "--silent"], { cwd: root });
	const temporaryRoot = await fs.mkdtemp(path.join(os.tmpdir(), "bcu-benchmark-broker-"));
	const brokerSocketPath = path.join(temporaryRoot, "broker.sock");
	const broker = spawn(process.execPath, [bundle, "__serve"], {
		cwd: root,
		env: { ...process.env, BCU_BROKER_SOCKET_PATH: brokerSocketPath, BCU_IDLE_MS: "100" },
		stdio: ["ignore", "ignore", "pipe", "pipe"],
	});
	let stderr = "";
	broker.stderr.setEncoding("utf8");
	broker.stderr.on("data", (chunk) => { stderr += chunk; });
	try {
		await Promise.race([
			once(broker.stdio[3], "data"),
			once(broker, "exit").then(([code, signal]) => { throw new Error(`Benchmark broker exited before ready (${signal ?? code}): ${stderr.trim()}`); }),
		]);
		const connection = await brokerConnection(brokerSocketPath);
		const handshake = await connection.call("hello");
		if (handshake.brokerVersion !== 1 || handshake.helperProtocolVersion !== protocolVersion) {
			throw new Error(`Unexpected broker handshake: ${JSON.stringify(handshake)}.`);
		}
		await connection.call("diagnostics");
		const samples = [];
		for (let sample = 0; sample < 10; sample += 1) {
			const startedAt = performance.now();
			const diagnostics = await connection.call("diagnostics");
			if (diagnostics.protocolVersion !== protocolVersion) throw new Error(`Expected protocol ${protocolVersion}, got ${diagnostics.protocolVersion}.`);
			samples.push(performance.now() - startedAt);
		}
		const { stdout: rssOutput } = await execFile("ps", ["-o", "rss=", "-p", String(broker.pid)]);
		connection.close();
		const [code, signal] = await once(broker, "exit");
		if (code !== 0 || signal) throw new Error(`Benchmark broker exit failed (${signal ?? code}): ${stderr.trim()}`);
		return {
			rttMs: { median: rounded(median(samples)), samples: samples.map(rounded) },
			idleRssMiB: rounded(Number(rssOutput.trim()) / 1024),
		};
	} finally {
		if (broker.exitCode === null && !broker.killed) broker.kill("SIGTERM");
		await fs.rm(temporaryRoot, { recursive: true, force: true });
	}
}

async function textEditLook() {
	const fixturePath = path.join(os.tmpdir(), "bcu-benchmark.txt");
	await fs.writeFile(fixturePath, "bcu benchmark\nThe quick brown fox jumps over the lazy dog.\n0123456789\n");
	await execFile("open", ["-a", "TextEdit", fixturePath]);
	const frontmost = await callHelper("getFrontmost");
	if (frontmost.bundleId !== "com.apple.TextEdit" || !Number.isFinite(frontmost.windowId)) {
		throw new Error("TextEdit did not expose a frontmost window. Activate its benchmark document and rerun.");
	}
	const startedAt = performance.now();
	const look = await callHelper("look", { windowId: frontmost.windowId, readText: "always" });
	return {
		target: { app: frontmost.appName, title: frontmost.windowTitle, windowId: frontmost.windowId },
		timings: { ...look.timings, rttMs: rounded(performance.now() - startedAt) },
	};
}

const existing = await currentDiagnostics();
await stopHelper(existing);
const coldStart = await coldStartHelper();
const permissions = await callHelper("checkPermissions");
if (permissions.source?.attribution !== "helper-app") throw new Error(`Unexpected TCC attribution: ${permissions.source?.attribution ?? "missing"}.`);
if (!permissions.accessibility || !permissions.screenRecordingCapturable) throw new Error("bcu requires Accessibility and Screen Recording before benchmarking.");
const brokerMetrics = await measureBrokerDiagnostics();
const { stdout: rssOutput } = await execFile("ps", ["-o", "rss=", "-p", String(coldStart.diagnostics.pid)]);
const helperIdleRssMiB = Number(rssOutput.trim()) / 1024;
const look = await textEditLook();
const [{ stdout: commit }, { stdout: macOS }] = await Promise.all([
	execFile("git", ["rev-parse", "HEAD"]),
	execFile("sw_vers"),
]);

console.log(JSON.stringify({
	commit: commit.trim(),
	macOS: macOS.trim(),
	brokerDiagnosticsRttMs: brokerMetrics.rttMs,
	lookTimingsMs: look.timings,
	brokerIdleRssMiB: brokerMetrics.idleRssMiB,
	helperIdleRssMiB: rounded(helperIdleRssMiB),
	combinedIdleRssMiB: rounded(brokerMetrics.idleRssMiB + helperIdleRssMiB),
	daemonColdStartMs: rounded(coldStart.elapsedMs),
	target: look.target,
}, null, 2));
