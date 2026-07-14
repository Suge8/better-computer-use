#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFile as execFileCallback } from "node:child_process";
import fs from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFile = promisify(execFileCallback);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temporaryRoot = await fs.mkdtemp(path.join(os.tmpdir(), "bcu-cubench-agent-"));
const socketPath = process.platform === "win32"
	? `\\\\.\\pipe\\bcu-cubench-${process.pid}`
	: path.join(temporaryRoot, "broker.sock");
const commands = [];
let done = false;

function brokerResult(command) {
	switch (command) {
		case "find-roots": return { details: { windows: [{ app: "Chromium", windowTitle: "Cubench", windowRef: "@r1", isFocused: true }] } };
		case "observe-ui": return { details: { capture: { stateId: "state-1" } } };
		case "search-ui": return { details: { stateId: "state-1", matches: [{ ref: "@e1", label: "Dark mode", role: "AXCheckBox" }] } };
		case "act-ui": return { details: { capture: { stateId: "state-2" }, execution: { outcome: "worked" } } };
		default: throw new Error(`Unexpected Cubench broker command ${command}`);
	}
}

const broker = net.createServer((socket) => {
	socket.setEncoding("utf8");
	let buffer = "";
	socket.on("data", (chunk) => {
		buffer += chunk;
		for (;;) {
			const newline = buffer.indexOf("\n");
			if (newline < 0) return;
			const request = JSON.parse(buffer.slice(0, newline));
			buffer = buffer.slice(newline + 1);
			if (request.cmd === "hello") {
				socket.write(`${JSON.stringify({ id: request.id, ok: true, result: { brokerVersion: 1, helperProtocolVersion: 6, pid: process.pid } })}\n`);
				continue;
			}
			commands.push({ command: request.cmd, args: request.args });
			socket.write(`${JSON.stringify({ id: request.id, ok: true, result: brokerResult(request.cmd) })}\n`);
		}
	});
});

const gateway = http.createServer((request, response) => {
	let body = "";
	request.setEncoding("utf8");
	request.on("data", (chunk) => { body += chunk; });
	request.on("end", () => {
		response.setHeader("content-type", "application/json");
		if (request.method === "POST" && request.url === "/session") {
			response.end(JSON.stringify({ instruction: "Turn on Dark mode." }));
			return;
		}
		if (request.method === "POST" && request.url === "/done") {
			done = JSON.parse(body).message === "done";
			response.end("{}");
			return;
		}
		response.statusCode = 404;
		response.end("{}");
	});
});

try {
	await Promise.all([
		new Promise((resolve, reject) => { broker.once("error", reject); broker.listen(socketPath, resolve); }),
		new Promise((resolve, reject) => { gateway.once("error", reject); gateway.listen(0, "127.0.0.1", resolve); }),
	]);
	const gatewayAddress = gateway.address();
	assert(gatewayAddress && typeof gatewayAddress === "object");
	await execFile(process.execPath, ["scripts/pi-cubench-agent.mjs"], {
		cwd: root,
		env: {
			...process.env,
			BCU_BROKER_SOCKET_PATH: socketPath,
			CUBENCH_GATEWAY: `http://127.0.0.1:${gatewayAddress.port}`,
		},
		timeout: 5_000,
	});
	assert.deepEqual(commands.map((entry) => entry.command), ["find-roots", "observe-ui", "search-ui", "act-ui"]);
	assert.equal(commands[2].args.stateId, "state-1", "Cubench search did not reuse the observed stateId");
	assert.equal(commands[3].args.stateId, "state-1", "Cubench act did not reuse the observed stateId");
	assert.equal(done, true, "Cubench adapter did not report completion");
	console.log("PASS Cubench adapter uses the shared broker for all tool commands");
} finally {
	await Promise.all([
		new Promise((resolve) => broker.close(resolve)),
		new Promise((resolve) => gateway.close(resolve)),
	]);
	await fs.rm(temporaryRoot, { recursive: true, force: true });
}
