#!/usr/bin/env node
// Builds the SwiftPM `bridge` product in release for each macOS architecture and places it
// at prebuilt/macos/<arch>/bridge, signed ad hoc with the helper bundle id; setup-helper.mjs
// installs that binary and re-signs the app with the machine-local identity.

import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { HELPER_BUNDLE_ID, SWIFT_ARCHS, prebuiltHelperPath } from "./lib/helper-target.mjs";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function requestedArchs() {
	const index = process.argv.indexOf("--arch");
	if (index < 0) return Object.keys(SWIFT_ARCHS);
	const arch = process.argv[index + 1];
	if (!(arch in SWIFT_ARCHS)) throw new Error(`Unsupported architecture '${arch}'. Supported: ${Object.keys(SWIFT_ARCHS).join(", ")}.`);
	return [arch];
}

async function run(command, args, { capture = false } = {}) {
	return await new Promise((resolve, reject) => {
		const child = spawn(command, args, { cwd: rootDir, stdio: ["ignore", capture ? "pipe" : "inherit", "inherit"] });
		let stdout = "";
		child.stdout?.on("data", (chunk) => { stdout += chunk; });
		child.on("error", reject);
		child.on("close", (code) => {
			if (code === 0) resolve(stdout.trim());
			else reject(new Error(`Command failed (${code}): ${command} ${args.join(" ")}`));
		});
	});
}

// SwiftPM writes every architecture to the same products directory, so each one is copied
// out before the next is built.
async function buildForArch(arch) {
	const args = ["build", "-c", "release", "--product", "bridge", "--arch", SWIFT_ARCHS[arch]];
	console.log(`Building native helper for ${arch}...`);
	await run("swift", args);
	const binPath = await run("swift", [...args, "--show-bin-path"], { capture: true });
	const outputPath = prebuiltHelperPath(rootDir, arch);
	await fs.mkdir(path.dirname(outputPath), { recursive: true });
	await fs.copyFile(path.join(binPath, "bridge"), outputPath);
	await fs.chmod(outputPath, 0o755);
	if (process.env.BCU_NO_SIGN !== "1") {
		await run("codesign", ["--force", "-i", HELPER_BUNDLE_ID, "--timestamp=none", "--sign", process.env.BCU_CODESIGN_IDENTITY ?? "-", outputPath]);
	}
	console.log(`Built helper at ${outputPath}`);
}

async function main() {
	if (process.platform !== "darwin") throw new Error(`The bcu helper is built on macOS; this host is ${process.platform}.`);
	for (const arch of requestedArchs()) await buildForArch(arch);
}

main().catch((error) => {
	console.error(error instanceof Error ? error.message : String(error));
	process.exit(1);
});
