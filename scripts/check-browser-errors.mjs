#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFile as execFileCallback, spawn } from "node:child_process";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP browser CLI errors (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The managed Helium error check requires macOS.");

const execFile = promisify(execFileCallback);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bundle = path.join(root, "dist", "bcu.mjs");
const server = http.createServer((_request, response) => {
	response.setHeader("content-type", "text/html");
	response.end("<title>bcu error fixture</title><button>Ready</button>");
});

function invoke(args, input = "") {
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

function assertFailure(result, code) {
	assert.notEqual(result.code, 0, `${code} exited zero`);
	assert.equal(result.stdout, "", `${code} wrote a false success to stdout`);
	assert.match(result.stderr, new RegExp(`^error ${code}: .+`, "m"));
	assert.match(result.stderr, /^recovery: .+/m);
}

await execFile("npm", ["run", "build", "--silent"], { cwd: root });
await new Promise((resolve, reject) => {
	server.once("error", reject);
	server.listen(0, "127.0.0.1", resolve);
});

try {
	const address = server.address();
	if (!address || typeof address === "string") throw new Error("Local fixture server has no TCP port.");
	const launched = JSON.parse((await execFile(process.execPath, [bundle, "browser", "launch", "--browser", "helium", "--url", `http://127.0.0.1:${address.port}`, "--json"], { cwd: root })).stdout);
	const rootRef = launched.result?.details?.roots?.[0]?.ref;
	assert(rootRef, "browser launch returned no root");
	const observed = JSON.parse((await execFile(process.execPath, [bundle, "observe-ui", "--root", rootRef, "--json"], { cwd: root })).stdout);
	const stateId = observed.result?.details?.stateId;
	assert(stateId, "browser observation returned no stateId");

	assertFailure(await invoke(["wait-for", "--state", stateId, "--text", "__BCU_NEVER_EXISTS__", "--timeout", "100", "--json"]), "action_timeout");
	assertFailure(await invoke(["act-ui", "--state", stateId, "--expect-text", "__BCU_NEVER_EXISTS__", "--timeout", "100", "-", "--json"], '[{"action":"wait","ms":0}]\n'), "action_failed");
	console.log("PASS browser wait and postcondition failures use nonzero stable errors");
} finally {
	await invoke(["stop"]);
	await new Promise((resolve) => server.close(resolve));
}
