import { execFile as execFileCallback, spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { npmInvocation } from "../npm-invocation.mjs";

const execFile = promisify(execFileCallback);

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
