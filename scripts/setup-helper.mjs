#!/usr/bin/env node
// Installs prebuilt/macos/<arch>/bridge as the bcu helper app and signs it with a
// machine-local identity that stays stable across reinstalls, because macOS keys
// Accessibility and Screen Recording grants to the code-signing identity.
// Building the helper belongs to build-native.mjs.

import { createHash } from "node:crypto";
import { spawn, execFile as execFileCallback } from "node:child_process";
import { constants as fsConstants, realpathSync, watch } from "node:fs";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { resolveMacosHelperAppPath } from "../src/macos/helper-path.mjs";
import { HELPER_BUNDLE_ID, MACOS_DEPLOYMENT_TARGET } from "./lib/helper-target.mjs";

const execFile = promisify(execFileCallback);
const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helperAppPath = resolveMacosHelperAppPath();
const helperAppExecutablePath = path.join(helperAppPath, "Contents", "MacOS", "bridge");
const helperSourceHashPath = path.join(helperAppPath, "Contents", "Resources", "source.sha256");
// Signing rewrites the Mach-O, so the installed binary never hashes to the source
// hash; a second manifest records the final post-sign bytes for tamper detection.
const helperInstalledHashPath = path.join(helperAppPath, "Contents", "Resources", "installed.sha256");
const packageJsonPath = path.join(rootDir, "package.json");
const localCodeSignCommonName = `bcu Local Signing (${HELPER_BUNDLE_ID})`;
const localSigningLockPath = path.join(os.tmpdir(), `bcu-local-signing-${typeof process.getuid === "function" ? process.getuid() : "user"}.lock`);

// npm postinstall must never fail the install of the package it belongs to.
const isPostinstall = process.argv.includes("--postinstall");

function normalizeArch(arch) {
	if (arch === "arm64" || arch === "x64") return arch;
	throw new Error(`Unsupported architecture '${arch}'. Supported: arm64, x64.`);
}

function prebuiltPathForArch(arch) {
	return path.join(rootDir, "prebuilt", "macos", arch, "bridge");
}

async function packageVersion() {
	const packageJson = JSON.parse(await fs.readFile(packageJsonPath, "utf8"));
	if (typeof packageJson.version !== "string" || packageJson.version.length === 0) {
		throw new Error(`Could not read package version from ${packageJsonPath}.`);
	}
	return packageJson.version;
}

async function exists(filePath) {
	try {
		await fs.access(filePath, fsConstants.F_OK);
		return true;
	} catch {
		return false;
	}
}

async function hashFile(filePath) {
	const data = await fs.readFile(filePath);
	return createHash("sha256").update(data).digest("hex");
}

// rename() swaps the inode, so an already running helper keeps its old binary
// instead of failing the install with ETXTBSY.
async function replaceExecutable(sourcePath, destinationPath) {
	await fs.mkdir(path.dirname(destinationPath), { recursive: true });
	const tempPath = `${destinationPath}.tmp-${process.pid}-${Date.now()}`;
	try {
		await fs.copyFile(sourcePath, tempPath);
		await fs.chmod(tempPath, 0o755);
		await fs.rename(tempPath, destinationPath);
	} catch (error) {
		await fs.rm(tempPath, { force: true }).catch(() => {});
		throw error;
	}
}

async function run(command, commandArgs) {
	await new Promise((resolve, reject) => {
		const child = spawn(command, commandArgs, { stdio: "inherit" });
		child.on("error", reject);
		child.on("close", (code) => {
			if (code === 0) {
				resolve();
				return;
			}
			reject(new Error(`Command failed (${code}): ${command} ${commandArgs.join(" ")}`));
		});
	});
}

async function commandOutput(command, commandArgs) {
	const { stdout } = await execFile(command, commandArgs, { encoding: "utf8" });
	return stdout;
}

export function parseCodeSigningIdentities(output, commonName = localCodeSignCommonName) {
	return output.split("\n")
		.map((line) => line.match(/^\s*\d+\)\s+([0-9A-F]{40})\s+"([^"]+)"/i))
		.filter((match) => match?.[2] === commonName)
		.map((match) => match[1].toUpperCase());
}

async function findLocalSigningIdentity() {
	// Self-signed local identities appear as CSSMERR_TP_NOT_TRUSTED and are
	// omitted by `-v`, but remain valid inputs to codesign. Match the identity
	// list directly and return its fingerprint rather than its display name.
	const output = await commandOutput("security", ["find-identity", "-p", "codesigning"]).catch(() => "");
	return parseCodeSigningIdentities(output)[0];
}

const localLockTails = new Map();

async function withLocalLockQueue(lockPath, callback) {
	const previous = localLockTails.get(lockPath) ?? Promise.resolve();
	let release;
	const turn = new Promise((resolve) => { release = resolve; });
	const tail = previous.then(() => turn);
	localLockTails.set(lockPath, tail);
	await previous;
	try {
		return await callback();
	} finally {
		release();
		if (localLockTails.get(lockPath) === tail) localLockTails.delete(lockPath);
	}
}

async function tryDirectoryLock(lockPath, staleMs) {
	try {
		await fs.mkdir(lockPath);
		return true;
	} catch (error) {
		if (error?.code !== "EEXIST") throw error;
	}
	const stat = await fs.stat(lockPath).catch(() => undefined);
	if (!stat || Date.now() - stat.mtimeMs <= staleMs) return false;
	await fs.rm(lockPath, { force: true, recursive: true }).catch(() => undefined);
	try {
		await fs.mkdir(lockPath);
		return true;
	} catch (error) {
		if (error?.code === "EEXIST") return false;
		throw error;
	}
}

async function acquireDirectoryLock(lockPath, { waitMs, staleMs }) {
	await fs.mkdir(path.dirname(lockPath), { recursive: true });
	if (await tryDirectoryLock(lockPath, staleMs)) return;
	const directory = path.dirname(lockPath);
	const filename = path.basename(lockPath);
	const watcher = watch(directory);
	await new Promise((resolve, reject) => {
		let acquiring = false;
		let eventQueued = false;
		let settled = false;
		const finish = (error) => {
			if (settled) return;
			settled = true;
			clearTimeout(timeout);
			watcher.close();
			if (error) reject(error);
			else resolve();
		};
		const acquire = async () => {
			if (settled) return;
			if (acquiring) {
				eventQueued = true;
				return;
			}
			acquiring = true;
			try {
				do {
					eventQueued = false;
					if (await tryDirectoryLock(lockPath, staleMs)) {
						finish();
						return;
					}
				} while (eventQueued && !settled);
			} catch (error) {
				finish(error);
			} finally {
				acquiring = false;
			}
		};
		const timeout = setTimeout(() => finish(new Error(`Timed out waiting for local signing identity lock at ${lockPath}.`)), waitMs);
		watcher.on("change", (_event, changed) => {
			if (changed !== null && String(changed) !== filename) return;
			eventQueued = true;
			void acquire();
		});
		watcher.on("error", finish);
		void acquire();
	});
}

export async function withDirectoryLock(lockPath, callback, { waitMs = 15_000, staleMs = 300_000 } = {}) {
	return await withLocalLockQueue(lockPath, async () => {
		await acquireDirectoryLock(lockPath, { waitMs, staleMs });
		try {
			return await callback();
		} finally {
			await fs.rm(lockPath, { force: true, recursive: true }).catch(() => undefined);
		}
	});
}

export async function ensureIdentityOnce(findIdentity, createIdentity, withLock) {
	return (await findIdentity()) ?? await withLock(async () => (await findIdentity()) ?? await createIdentity());
}

async function loginKeychainPath() {
	for (const candidate of [
		path.join(os.homedir(), "Library", "Keychains", "login.keychain-db"),
		path.join(os.homedir(), "Library", "Keychains", "login.keychain"),
	]) {
		if (await exists(candidate)) return candidate;
	}
	return undefined;
}

async function ensureLocalSigningIdentity() {
	if (!(await commandOutput("which", ["codesign"]).catch(() => ""))) return undefined;
	const existingIdentity = await findLocalSigningIdentity();
	if (existingIdentity) return existingIdentity;
	if (!(await commandOutput("which", ["openssl"]).catch(() => ""))) return undefined;
	if (!(await loginKeychainPath())) return undefined;

	return await ensureIdentityOnce(findLocalSigningIdentity, createLocalSigningIdentity, (callback) => withDirectoryLock(localSigningLockPath, callback));
}

async function createLocalSigningIdentity() {
	const keychain = await loginKeychainPath();
	if (!keychain) return undefined;
	const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "bcu-signing-"));
	const password = `bcu-local-${process.pid}-${Date.now()}`;
	try {
		const configPath = path.join(tempDir, "req.cnf");
		await fs.writeFile(configPath, [
			"[req]",
			"distinguished_name=dn",
			"x509_extensions=ext",
			"prompt=no",
			"[dn]",
			`CN=${localCodeSignCommonName}`,
			"[ext]",
			"basicConstraints=critical,CA:FALSE",
			"keyUsage=critical,digitalSignature",
			"extendedKeyUsage=critical,codeSigning",
			"",
		].join("\n"));
		const keyPath = path.join(tempDir, "key.pem");
		const certPath = path.join(tempDir, "cert.pem");
		const p12Path = path.join(tempDir, "id.p12");
		await execFile("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-keyout", keyPath, "-out", certPath, "-days", "3650", "-nodes", "-config", configPath]);
		await execFile("openssl", ["pkcs12", "-export", "-legacy", "-inkey", keyPath, "-in", certPath, "-out", p12Path, "-passout", `pass:${password}`, "-name", localCodeSignCommonName])
			.catch(async () => {
				await execFile("openssl", ["pkcs12", "-export", "-inkey", keyPath, "-in", certPath, "-out", p12Path, "-passout", `pass:${password}`, "-name", localCodeSignCommonName]);
			});
		await execFile("security", ["import", p12Path, "-k", keychain, "-P", password, "-A", "-T", "/usr/bin/codesign"]);
		const identity = await findLocalSigningIdentity();
		if (!identity) throw new Error("Imported local signing certificate is not a valid code-signing identity.");
		return identity;
	} catch (error) {
		console.warn(`[bcu] could not create a valid local signing identity: ${error instanceof Error ? error.message : String(error)}`);
		return undefined;
	} finally {
		await fs.rm(tempDir, { force: true, recursive: true }).catch(() => {});
	}
}

async function resolveCodeSignIdentity() {
	if (process.env.BCU_CODESIGN_IDENTITY) return process.env.BCU_CODESIGN_IDENTITY;
	return (await ensureLocalSigningIdentity()) ?? "-";
}

async function signHelper() {
	if (process.env.BCU_NO_SIGN === "1") return;
	const identity = await resolveCodeSignIdentity();
	await run("codesign", ["--force", "--deep", "-i", HELPER_BUNDLE_ID, "--timestamp=none", "--sign", identity, helperAppPath]);
	if (identity === "-") {
		console.warn("[bcu] warning: signed helper ad-hoc; macOS will ask for Accessibility and Screen Recording again after every reinstall.");
	}
}

async function registerHelperApp() {
	const lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
	if (!(await exists(lsregister))) return;
	await run(lsregister, ["-f", helperAppPath]).catch(() => {});
}

async function ensureHelperParentDirectory() {
	const parentPath = path.dirname(helperAppPath);
	await fs.mkdir(parentPath, { recursive: true });
	await fs.access(parentPath, fsConstants.W_OK);
}

function infoPlist(version) {
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${HELPER_BUNDLE_ID}</string>
<key>CFBundleName</key><string>bcu</string>
<key>CFBundleDisplayName</key><string>bcu</string>
<key>CFBundleExecutable</key><string>bridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>${version}</string>
<key>LSMinimumSystemVersion</key><string>${MACOS_DEPLOYMENT_TARGET}</string>
<key>LSUIElement</key><true/>
</dict></plist>\n`;
}

async function installHelperApp(sourcePath) {
	await ensureHelperParentDirectory();
	const plist = infoPlist(await packageVersion());
	const plistPath = path.join(helperAppPath, "Contents", "Info.plist");
	const sourceHash = await hashFile(sourcePath);
	const [installedSourceHash, installedHashManifest, installedPlist, installedHash] = await Promise.all([
		fs.readFile(helperSourceHashPath, "utf8").then((text) => text.trim(), () => undefined),
		fs.readFile(helperInstalledHashPath, "utf8").then((text) => text.trim(), () => undefined),
		fs.readFile(plistPath, "utf8").catch(() => undefined),
		hashFile(helperAppExecutablePath).catch(() => undefined),
	]);
	// Current means: same source generation AND the installed bytes are untampered.
	if (installedSourceHash === sourceHash && installedPlist === plist && installedHash !== undefined && installedHash === installedHashManifest) {
		await registerHelperApp();
		return false;
	}

	await replaceExecutable(sourcePath, helperAppExecutablePath);
	await fs.mkdir(path.dirname(helperSourceHashPath), { recursive: true });
	await fs.writeFile(plistPath, plist);
	await fs.writeFile(helperSourceHashPath, `${sourceHash}\n`);
	await signHelper();
	await fs.writeFile(helperInstalledHashPath, `${await hashFile(helperAppExecutablePath)}\n`);
	await registerHelperApp();
	return true;
}

async function setup() {
	if (process.platform !== "darwin") throw new Error(`The bcu helper only supports macOS; this host is ${process.platform}.`);

	const arch = normalizeArch(process.arch);
	const prebuiltPath = prebuiltPathForArch(arch);
	if (!(await exists(prebuiltPath))) {
		throw new Error(`No prebuilt helper found for ${arch} at ${prebuiltPath}. Run 'npm run build:native'.`);
	}

	const installed = await installHelperApp(prebuiltPath);
	console.log(
		installed
			? `[bcu] installed helper app (${arch}) at ${helperAppPath}`
			: `[bcu] helper app (${arch}) already current at ${helperAppPath}`,
	);
}

// realpath both sides so symlinked entrypoints match; eval/import hosts have no real argv[1] path.
const isMain = (() => {
	if (!process.argv[1]) return false;
	try {
		return realpathSync(path.resolve(process.argv[1])) === realpathSync(fileURLToPath(import.meta.url));
	} catch {
		return false;
	}
})();
if (isMain) setup().catch((error) => {
	const message = error instanceof Error ? error.message : String(error);
	if (isPostinstall) {
		console.warn(`[bcu] postinstall helper setup skipped: ${message}`);
		process.exit(0);
	}

	console.error(message);
	process.exit(1);
});
