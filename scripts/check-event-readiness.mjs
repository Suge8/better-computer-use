#!/usr/bin/env node
// Readiness waits on filesystem events instead of polling, and still fails with a named
// timeout when the event never arrives.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { waitForPathReady } from "../src/readiness.ts";

const temporaryRoot = await fs.mkdtemp(path.join(os.tmpdir(), "bcu-event-readiness-"));
try {
	const marker = path.join(temporaryRoot, "socket-ready");
	let eventChecks = 0;
	await waitForPathReady(
		marker,
		() => { setImmediate(() => void fs.writeFile(marker, "ready")); },
		async () => {
			eventChecks += 1;
			try { await fs.access(marker); return true; } catch { return false; }
		},
		{ timeoutMs: 1_000, description: "event-created readiness marker" },
	);
	assert(eventChecks >= 2 && eventChecks <= 3, `path readiness made unexpected checks without events: ${eventChecks}`);

	const absent = path.join(temporaryRoot, "never-ready");
	let idleChecks = 0;
	await assert.rejects(
		waitForPathReady(
			absent,
			() => undefined,
			() => { idleChecks += 1; return false; },
			{ timeoutMs: 50, description: "absent readiness marker" },
		),
		/Timed out waiting for absent readiness marker/,
	);
	assert.equal(idleChecks, 2, "path readiness periodically rechecked without a filesystem event");

	console.log("PASS readiness waits on filesystem events without polling");
} finally {
	await fs.rm(temporaryRoot, { recursive: true, force: true });
}
