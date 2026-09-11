#!/usr/bin/env node

import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { HELPER_BUNDLE_ID, HELPER_FRAMEWORKS, HELPER_SOURCE_FILES, helperTargetTriple } from "./lib/helper-target.mjs";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const macosSourcePaths = HELPER_SOURCE_FILES.map((file) => path.join(rootDir, "native", "macos", file));

async function exists(filePath) {
	try {
		await fs.access(filePath);
		return true;
	} catch {
		return false;
	}
}

function getArg(name) {
	const index = process.argv.indexOf(name);
	if (index >= 0 && index + 1 < process.argv.length) {
		return process.argv[index + 1];
	}
	return undefined;
}

function hasArg(name) {
	return process.argv.includes(name);
}

function normalizeArch(arch) {
	if (arch === "universal" || arch === "all") return arch;
	if (arch === "arm64" || arch === "x64") return arch;
	throw new Error(`Unsupported architecture '${arch}'. Supported: arm64, x64, universal, all.`);
}

async function run(command, args) {
	await new Promise((resolve, reject) => {
		const child = spawn(command, args, { stdio: "inherit" });
		child.on("error", reject);
		child.on("close", (code) => {
			if (code === 0) {
				resolve();
				return;
			}
			reject(new Error(`Command failed (${code}): ${command} ${args.join(" ")}`));
		});
	});
}

function defaultOutputPath(arch) {
	return path.join(rootDir, "prebuilt", "macos", arch, "bridge");
}

function moduleCachePath(arch) {
	return path.join(os.tmpdir(), `bcu-swift-module-cache-${arch}`);
}

function swiftArgsForArch(arch, outputPath) {
	const args = [
		"swiftc",
		"-target",
		helperTargetTriple(arch),
		"-module-cache-path",
		moduleCachePath(arch),
		"-O",
	];
	for (const framework of HELPER_FRAMEWORKS) args.push("-framework", framework);
	args.push(...macosSourcePaths, "-o", outputPath);
	return args;
}

async function signBinary(outputPath) {
	if (hasArg("--no-sign") || process.env.BCU_NO_SIGN === "1") {
		return;
	}

	const identity = getArg("--sign-identity") ?? process.env.BCU_CODESIGN_IDENTITY ?? "-";
	const identifier = getArg("--sign-identifier") ?? process.env.BCU_CODESIGN_IDENTIFIER ?? HELPER_BUNDLE_ID;
	const args = ["--force", "-i", identifier];
	if (hasArg("--hardened-runtime")) {
		args.push("--options", "runtime");
	}
	if (hasArg("--timestamp")) {
		args.push("--timestamp");
	} else {
		args.push("--timestamp=none");
	}
	args.push("--sign", identity, outputPath);
	await run("codesign", args);
}

async function buildForArch(arch, outputPath) {
	await fs.mkdir(path.dirname(outputPath), { recursive: true });
	console.log(`Building native helper for ${arch}...`);
	await run("xcrun", swiftArgsForArch(arch, outputPath));
	await fs.chmod(outputPath, 0o755);
	await signBinary(outputPath);
	console.log(`Built helper at ${outputPath}`);
}

async function buildUniversal(outputPath) {
	const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "bcu-build-"));
	const x64Output = path.join(tempDir, "bridge-x64");
	const arm64Output = path.join(tempDir, "bridge-arm64");
	await buildForArch("x64", x64Output);
	await buildForArch("arm64", arm64Output);
	await fs.mkdir(path.dirname(outputPath), { recursive: true });
	await run("lipo", ["-create", "-output", outputPath, x64Output, arm64Output]);
	await fs.chmod(outputPath, 0o755);
	await signBinary(outputPath);
	console.log(`Built universal helper at ${outputPath}`);
	await fs.rm(tempDir, { recursive: true, force: true });
}

async function main() {
	if (process.platform !== "darwin") throw new Error(`The bcu helper is built on macOS; this host is ${process.platform}.`);

	const arch = normalizeArch(getArg("--arch") ?? process.arch);
	const outputArg = getArg("--output");

	if (arch === "all") {
		if (outputArg) {
			throw new Error("--output is not supported with --arch all. Use a single architecture for one output.");
		}
		for (const nextArch of ["x64", "arm64"]) {
			await buildForArch(nextArch, defaultOutputPath(nextArch));
		}
		return;
	}

	const outputPath = outputArg ? path.resolve(process.cwd(), outputArg) : defaultOutputPath(arch);
	if (arch === "universal") {
		await buildUniversal(outputPath);
		return;
	}

	await buildForArch(arch, outputPath);
}

main().catch((error) => {
	console.error(error instanceof Error ? error.message : String(error));
	process.exit(1);
});
