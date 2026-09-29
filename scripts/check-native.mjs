#!/usr/bin/env node
// The Swift helper compiles against the frameworks it uses, and the agent cursor's
// animation lifecycle and the OCR line attachment behave as their unit tests describe.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { HELPER_FRAMEWORKS, HELPER_SOURCE_FILES, helperTargetTriple } from "./lib/helper-target.mjs";

if (process.platform !== "darwin") {
	console.log("SKIP native checks (macOS only)");
	process.exit(0);
}

const root = fileURLToPath(new URL("..", import.meta.url));
const triple = helperTargetTriple(process.arch);

execFileSync("xcrun", [
	"swiftc", "-target", triple, "-parse-as-library",
	"-module-cache-path", path.join(os.tmpdir(), `bcu-swift-typecheck-${process.arch}`),
	...HELPER_FRAMEWORKS.flatMap((framework) => ["-framework", framework]),
	"-typecheck",
	...HELPER_SOURCE_FILES.map((file) => `native/macos/${file}`),
], { cwd: root, stdio: "pipe" });

/** Compiles one unit-test executable from helper sources and runs it; it exits non-zero on failure. */
function runUnitTests(name, frameworks, sources) {
	const binary = path.join(os.tmpdir(), `bcu-${name}-tests-${process.pid}`);
	try {
		execFileSync("xcrun", [
			"swiftc", "-target", triple, "-parse-as-library",
			"-module-cache-path", path.join(os.tmpdir(), `bcu-${name}-test-cache-${process.arch}`),
			...frameworks.flatMap((framework) => ["-framework", framework]),
			...sources.map((file) => `native/macos/${file}`),
			"-o", binary,
		], { cwd: root, stdio: "pipe" });
		execFileSync(binary, [], { cwd: root, stdio: "pipe" });
	} finally {
		fs.rmSync(binary, { force: true });
	}
}

runUnitTests("cursor", ["AppKit", "SwiftUI"], ["agent_cursor.swift", "agent_cursor_motion.swift", "agent_cursor_tests.swift"]);
runUnitTests("look-outline", ["ApplicationServices"], ["look_outline.swift", "look_outline_tests.swift"]);

console.log("PASS native helper typecheck, agent cursor lifecycle and OCR attachment");
