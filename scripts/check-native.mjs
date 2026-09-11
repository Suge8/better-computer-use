#!/usr/bin/env node
// The Swift helper compiles against the frameworks it uses, and the agent cursor's
// animation lifecycle behaves as its own unit tests describe.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { HELPER_FRAMEWORKS, helperTargetTriple } from "./lib/helper-target.mjs";

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
	"native/macos/agent_cursor.swift",
	"native/macos/agent_cursor_motion.swift",
	"native/macos/bridge.swift",
], { cwd: root, stdio: "pipe" });

const binary = path.join(os.tmpdir(), `bcu-cursor-tests-${process.pid}`);
try {
	execFileSync("xcrun", [
		"swiftc", "-target", triple, "-parse-as-library",
		"-module-cache-path", path.join(os.tmpdir(), `bcu-cursor-test-cache-${process.arch}`),
		"-framework", "AppKit",
		"-framework", "SwiftUI",
		"native/macos/agent_cursor.swift",
		"native/macos/agent_cursor_motion.swift",
		"native/macos/agent_cursor_tests.swift",
		"-o", binary,
	], { cwd: root, stdio: "pipe" });
	execFileSync(binary, [], { cwd: root, stdio: "pipe" });
} finally {
	fs.rmSync(binary, { force: true });
}

console.log("PASS native helper typecheck and agent cursor lifecycle");
