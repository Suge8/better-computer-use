#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { ensureIdentityOnce, parseCodeSigningIdentities, withDirectoryLock } from "./setup-helper.mjs";

const sample = `
Policy: Code Signing
  Matching identities
  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "bcu Local Signing (com.sugeh.bcu)" (CSSMERR_TP_NOT_TRUSTED)
  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "bcu Local Signing" (CSSMERR_TP_NOT_TRUSTED)
  3) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC "bcu Local Signing (com.sugeh.bcu)" (CSSMERR_TP_NOT_TRUSTED)
     3 identities found
`;

assert.deepEqual(parseCodeSigningIdentities(sample), [
	"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
	"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
]);

const setupCopy = await fs.readFile(new URL("./setup-helper.mjs", import.meta.url), "utf8");
assert.doesNotMatch(setupCopy, /tccutil[\s\S]{0,80}reset|resetTcc/i);

const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "bcu-signing-test-"));
const lockPath = path.join(tempDir, "identity.lock");
let identity;
let createCount = 0;
let releaseCreation;
const creationReleased = new Promise((resolve) => { releaseCreation = resolve; });
let creationStarted;
const started = new Promise((resolve) => { creationStarted = resolve; });

try {
	const operations = Array.from({ length: 12 }, () => ensureIdentityOnce(
		async () => identity,
		async () => {
			createCount++;
			creationStarted();
			await creationReleased;
			identity = "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD";
			return identity;
		},
		(callback) => withDirectoryLock(lockPath, callback, { waitMs: 2_000 }),
	));
	await started;
	setImmediate(releaseCreation);
	const results = await Promise.all(operations);

	assert.equal(createCount, 1, "concurrent callers must create only one identity");
	assert.deepEqual(new Set(results), new Set([identity]));

	await fs.mkdir(lockPath);
	await assert.rejects(
		withDirectoryLock(lockPath, async () => undefined, { waitMs: 50, staleMs: 60_000 }),
		/Timed out waiting for local signing identity lock/,
		"lock waiter did not honor its event-only timeout boundary",
	);
	await fs.rm(lockPath, { recursive: true });

	const processLock = path.join(tempDir, "process.lock");
	const activePath = path.join(tempDir, "active");
	const logPath = path.join(tempDir, "processes.log");
	const setupUrl = new URL("./setup-helper.mjs", import.meta.url).href;
	const workerSource = [
		"import fs from 'node:fs/promises'",
		"const { withDirectoryLock } = await import(process.argv[1])",
		"const [lockPath, activePath, logPath] = process.argv.slice(2)",
		"await withDirectoryLock(lockPath, async () => {",
		"  await fs.writeFile(activePath, String(process.pid), { flag: 'wx' })",
		"  await fs.appendFile(logPath, `${process.pid}\\n`)",
		"  await new Promise((resolve) => setImmediate(resolve))",
		"  await fs.rm(activePath)",
		"}, { waitMs: 5_000 })",
	].join("\n");
	const workers = Array.from({ length: 8 }, () => {
		const child = spawn(process.execPath, ["--input-type=module", "-e", workerSource, setupUrl, processLock, activePath, logPath], {
			stdio: ["ignore", "ignore", "pipe"],
		});
		let stderr = "";
		child.stderr.setEncoding("utf8");
		child.stderr.on("data", (chunk) => { stderr += chunk; });
		return once(child, "exit").then(([code, signal]) => {
			assert.equal(signal, null, `signing lock worker exited by ${signal}`);
			assert.equal(code, 0, `signing lock worker failed: ${stderr.trim()}`);
		});
	});
	await Promise.all(workers);
	const processIds = (await fs.readFile(logPath, "utf8")).trim().split("\n");
	assert.equal(processIds.length, 8, "cross-process signing lock lost a waiter");
	assert.equal(new Set(processIds).size, 8, "cross-process signing lock repeated a worker");
} finally {
	await fs.rm(tempDir, { force: true, recursive: true });
}

console.log("[check-local-signing] stable identity, non-destructive install, and concurrent creation passed");
