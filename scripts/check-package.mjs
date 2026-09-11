#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFile as execFileCallback } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { npmInvocation } from "./npm-invocation.mjs";

const execFile = promisify(execFileCallback);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const [npmBuild, npmBuildArgs] = npmInvocation(["run", "build", "--silent"]);
await execFile(npmBuild, npmBuildArgs, { cwd: root });
const [npmPack, npmPackArgs] = npmInvocation(["pack", "--dry-run", "--json", "--ignore-scripts"]);
const { stdout } = await execFile(npmPack, npmPackArgs, {
	cwd: root,
	maxBuffer: 16 * 1024 * 1024,
});
const report = JSON.parse(stdout)[0];
assert(report && Array.isArray(report.files), "npm pack did not return a file manifest");
const files = new Set(report.files.map((entry) => entry.path));
for (const required of [
	"dist/bcu.mjs",
	"prebuilt/macos/arm64/bridge",
	"prebuilt/macos/x64/bridge",
	"native/macos/bridge.swift",
	"scripts/setup-helper.mjs",
]) {
	assert(files.has(required), `npm tarball is missing ${required}`);
}
for (const file of files) {
	assert(!/^(prebuilt|native|src)\/(windows|linux)\//.test(file), `npm tarball still ships a non-macOS helper: ${file}`);
}
const bundle = await fs.readFile(path.join(root, "dist", "bcu.mjs"), "utf8");
assert(bundle.startsWith("#!/usr/bin/env node\n"), "dist/bcu.mjs is not an executable CLI entrypoint");

// macOS runtime repair: a replaced helper binary must be restored by ensureInstalled
// (guards against an early-return that skips the per-session setup sync).
const macosHelper = await fs.readFile(path.join(root, "prebuilt", "macos", process.arch === "arm64" ? "arm64" : "x64", "bridge"));
const clientRoot = await fs.mkdtemp(path.join(os.tmpdir(), "bcu-install-check-"));
const clientApp = path.join(clientRoot, "bcu.app");
const clientExecutable = path.join(clientApp, "Contents", "MacOS", "bridge");
const previousEnvironment = { BCU_HELPER_APP_PATH: process.env.BCU_HELPER_APP_PATH, BCU_NO_SIGN: process.env.BCU_NO_SIGN };
try {
	process.env.BCU_HELPER_APP_PATH = clientApp;
	process.env.BCU_NO_SIGN = "1";
	await execFile(process.execPath, [path.join(root, "scripts", "setup-helper.mjs"), "--runtime"], { cwd: root, env: process.env });
	await fs.copyFile("/bin/echo", clientExecutable);
	const { MacosHelperClient } = await import("../src/macos/helper.ts");
	const repairClient = new MacosHelperClient();
	try {
		await repairClient.ensureInstalled();
		assert.equal((await fs.readFile(clientExecutable)).equals(macosHelper), true, "runtime check did not repair a replaced helper binary");
	} finally {
		repairClient.dispose();
	}
} finally {
	for (const [key, value] of Object.entries(previousEnvironment)) {
		if (value === undefined) delete process.env[key]; else process.env[key] = value;
	}
	await fs.rm(clientRoot, { recursive: true, force: true });
}

console.log(`Package manifest checks passed (${report.entryCount} files, ${report.size} bytes packed; macOS runtime repair verified).`);
