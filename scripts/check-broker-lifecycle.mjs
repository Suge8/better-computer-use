#!/usr/bin/env node
// One broker per user, started and stopped without polling: concurrent clients elect a
// single server, a stale socket is replaced, stop ends it, and it exits on idle.
import assert from "node:assert/strict";
import { execFile as execFileCallback } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";
import {
	brokerEnvironment,
	brokerRequest,
	buildBundle,
	killProcess,
	makeTemporaryRoot,
	rejectAfter,
	repoRoot,
	spawnBroker,
} from "./lib/harness.mjs";

const execFile = promisify(execFileCallback);
const temporaryRoot = await makeTemporaryRoot("broker-lifecycle");
const livePids = new Set();

function connect(socketPath) {
	return new Promise((resolve, reject) => {
		const socket = net.createConnection(socketPath);
		socket.once("connect", () => { socket.destroy(); resolve(); });
		socket.once("error", reject);
	});
}

async function isolatedEnvironment(label, idleMs) {
	const directory = path.join(temporaryRoot, label);
	await fs.mkdir(directory);
	const socketPath = path.join(directory, "broker.sock");
	return { directory, socketPath, env: brokerEnvironment(socketPath, idleMs) };
}

function kill(pid) {
	if (killProcess(pid)) livePids.delete(pid);
}

async function sourceAgentStart() {
	const { env } = await isolatedEnvironment("source-agent", 60_000);
	const clientUrl = pathToFileURL(path.join(repoRoot, "src", "client.ts")).href;
	const source = `import { requestBroker } from ${JSON.stringify(clientUrl)}; console.log(JSON.stringify(await requestBroker("ping", {})))`;
	const { stdout } = await execFile(process.execPath, ["--input-type=module", "-e", source], { cwd: repoRoot, env });
	const reply = JSON.parse(stdout);
	assert(Number.isInteger(reply.pid), "source agent did not start a broker");
	livePids.add(reply.pid);
	kill(reply.pid);
	console.log(`PASS source agent started broker ${reply.pid} through client.ts`);
}

async function concurrentStartAndRecovery() {
	const { directory, socketPath, env } = await isolatedEnvironment("race", 60_000);
	const replies = await Promise.all(Array.from({ length: 20 }, () => brokerRequest("ping", {}, env)));
	const pids = new Set(replies.map((reply) => reply.pid));
	assert.equal(pids.size, 1, `concurrent clients started multiple brokers: ${[...pids].join(", ")}`);
	const [pid] = pids;
	livePids.add(pid);
	assert.equal((await fs.stat(directory)).mode & 0o777, 0o700, "broker cache directory is not mode 0700");
	assert.equal((await fs.stat(socketPath)).mode & 0o777, 0o600, "broker socket is not mode 0600");

	const monitor = net.createConnection(socketPath);
	monitor.on("error", () => undefined);
	await once(monitor, "connect");
	const closed = once(monitor, "close");
	kill(pid);
	await Promise.race([closed, rejectAfter("killed broker connection to close", 5_000)]);

	await fs.stat(socketPath);
	const recoveredReplies = await Promise.all(Array.from({ length: 30 }, () => brokerRequest("ping", {}, env)));
	const recoveredPids = new Set(recoveredReplies.map((reply) => reply.pid));
	assert.equal(recoveredPids.size, 1, `stale cleanup split clients across brokers: ${[...recoveredPids].join(", ")}`);
	const [recoveredPid] = recoveredPids;
	assert.notEqual(recoveredPid, pid, "clients reused the killed broker pid");
	livePids.add(recoveredPid);
	kill(recoveredPid);
	console.log(`PASS 20 clients shared broker ${pid}; 30 stale-socket clients recovered as ${recoveredPid}`);
}

async function idleExit() {
	const { socketPath, env } = await isolatedEnvironment("idle", 2_000);
	const broker = spawnBroker(env);
	await Promise.race([
		once(broker.ready, "data"),
		once(broker.process, "exit").then(([code, signal]) => { throw new Error(`Idle broker exited before ready (${signal ?? code}): ${broker.stderr().trim()}`); }),
		rejectAfter("idle broker readiness", 5_000),
	]);
	const reply = await brokerRequest("ping", {}, env);
	assert.equal(reply.pid, broker.process.pid, "request did not connect to the directly started idle broker");
	const [code, signal] = await Promise.race([once(broker.process, "exit"), rejectAfter("idle broker exit", 8_000)]);
	assert.equal(signal, null, `idle broker exited by signal ${signal}`);
	assert.equal(code, 0, `idle broker exited ${code}: ${broker.stderr().trim()}`);
	await assert.rejects(fs.stat(socketPath), (error) => error?.code === "ENOENT", "idle broker left its socket behind");
	await assert.rejects(connect(socketPath), (error) => error?.code === "ENOENT" || error?.code === "ECONNREFUSED", "idle broker socket remained connectable");
	console.log("PASS broker exited after BCU_IDLE_MS=2000 without polling");
}

try {
	await buildBundle();
	await sourceAgentStart();
	await concurrentStartAndRecovery();
	await idleExit();
} finally {
	for (const pid of livePids) kill(pid);
	await fs.rm(temporaryRoot, { recursive: true, force: true });
}
