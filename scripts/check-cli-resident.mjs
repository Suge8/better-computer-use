#!/usr/bin/env node
// The CLI's side of the resident process, black box against the bcu executable built from
// this checkout. Against a scripted resident on the socket: status and stop report it,
// doctor shows its permissions and the local config, act-ui carries the headless setting of
// the environment and of the config file, the agent cursor motion is chosen in the config
// file and overridden per field by BCU_CURSOR_MOTION_* (an unknown value is refused with the
// allowed ones), and a resident speaking another protocol is refused. Against a test bundle of this build: status and stop never start a resident, a
// command starts one through LaunchServices that serves on the caller's socket, and stop
// ends it. The bundle holds no grants, so the command is refused as permission_missing: the
// resident reads the grants without asking for them (only `bcu setup` asks).
import assert from "node:assert/strict";
import { execFile as execFileCallback } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import fs from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { promisify } from "node:util";
import { makeTemporaryRoot, monitorProcess, runCli, useBuiltCli, withTimeout } from "./lib/harness.mjs";

const execFile = promisify(execFileCallback);
const binary = await useBuiltCli();
const root = await makeTemporaryRoot("cli-resident");
const socketPath = path.join(root, "resident.sock");
const home = path.join(root, "home");
const env = { ...process.env, HOME: home, BCU_SOCKET_PATH: socketPath, BCU_APP_PATH: path.join(root, "missing.app") };

const DEFAULT_MOTION = { style: "signature_arc", timing: "native", effects: { trail: false, glow: true, magnet: false, ripple: true, squish: true } };

const ACT_RESULT = { stateId: "bbbbbbbb", baseStateId: "abcd1234", outcome: "worked", verification: { status: "none" }, delivery: "ax", changes: [] };

/** The wire protocol this bcu speaks, read from its one definition. */
const PROTOCOL = Number(/wireProtocolVersion = (\d+)/.exec(readFileSync(new URL("../Sources/BCURuntime/Wire.swift", import.meta.url), "utf8"))?.[1]);

/** A resident that speaks the wire protocol from a script and records what it was asked. */
async function scriptedResident(protocolVersion = PROTOCOL) {
	const requests = [];
	const server = net.createServer((socket) => {
		let buffer = "";
		socket.setEncoding("utf8");
		socket.on("data", (chunk) => {
			buffer += chunk;
			for (let newline = buffer.indexOf("\n"); newline >= 0; newline = buffer.indexOf("\n")) {
				const message = JSON.parse(buffer.slice(0, newline));
				buffer = buffer.slice(newline + 1);
				socket.write(`${JSON.stringify(reply(message))}\n`);
				if (message.command === "stop") server.close();
			}
		});
		socket.on("error", () => undefined);
	});
	const status = { pid: process.pid, protocolVersion };
	function reply(message) {
		if ("hello" in message) return { hello: status };
		requests.push(message);
		if (message.command === "stop") return { result: status };
		if (message.command === "doctor") return { result: { permissions: { accessibility: true, screenRecording: false } } };
		if (message.command === "act-ui") return { result: ACT_RESULT };
		return { error: { code: "internal_error", message: `scripted resident has no ${message.command}`, recovery: "none" } };
	}
	await new Promise((resolve) => server.listen(socketPath, resolve));
	return { requests, closed: new Promise((resolve) => server.once("close", resolve)), close: () => server.close() };
}

async function json(args, extraEnv = {}) {
	const result = await runCli([...args, "--json"], { env: { ...env, ...extraEnv } });
	assert.equal(result.code, 0, `bcu ${args.join(" ")} exited ${result.code}: ${result.stderr}`);
	return JSON.parse(result.stdout);
}

async function text(args) {
	const result = await runCli(args, { env });
	assert.equal(result.code, 0, `bcu ${args.join(" ")} exited ${result.code}: ${result.stderr}`);
	return result.stdout;
}

async function headlessSent(extraEnv) {
	const resident = await scriptedResident();
	try {
		const result = await runCli(["act-ui", "--state", "abcd1234", "-"], { input: JSON.stringify([{ action: "click", ref: "@e1" }]), env: { ...env, ...extraEnv } });
		assert.equal(result.code, 0, `act-ui exited ${result.code}: ${result.stderr}`);
		return resident.requests.find((message) => message.command === "act-ui").params.headless === true;
	} finally {
		resident.close();
		await resident.closed;
	}
}

async function scriptedChecks() {
	const resident = await scriptedResident();
	assert.equal(await text(["status"]), `resident running · pid ${process.pid} · protocol ${PROTOCOL}\n`);
	assert.deepEqual(await json(["status"]), { running: true, pid: process.pid, protocolVersion: PROTOCOL });
	assert.equal(await text(["doctor"]), `resident ok · pid ${process.pid} · protocol ${PROTOCOL}\npermissions: accessibility=true screenRecording=false\n`);
	const doctor = await json(["doctor"]);
	assert.deepEqual(doctor.permissions, { accessibility: true, screenRecording: false }, "doctor --json lost the resident's permissions");
	assert.deepEqual(doctor.config.config, { headless: false, cursor_overlay: true, cursor_motion: DEFAULT_MOTION }, "doctor --json does not report the default config");
	assert.equal(await text(["stop"]), `resident stopped · pid ${process.pid}\n`);
	await resident.closed;

	assert.equal(await headlessSent({}), false, "act-ui went headless with nothing asking for it");
	assert.equal(await headlessSent({ BCU_HEADLESS: "yes" }), true, "BCU_HEADLESS=yes did not make act-ui headless");
	await fs.mkdir(path.join(home, ".config", "bcu"), { recursive: true });
	await fs.writeFile(path.join(home, ".config", "bcu", "config.json"), JSON.stringify({ computer_use: { headless: "on" } }));
	assert.equal(await headlessSent({}), true, "headless in the config file did not make act-ui headless");
	assert.equal(await headlessSent({ BCU_HEADLESS: "0" }), false, "BCU_HEADLESS=0 did not override the config file");
	await fs.rm(path.join(home, ".config"), { recursive: true });

	await cursorMotionChecks();

	const foreign = await scriptedResident(PROTOCOL + 1);
	try {
		const refused = await runCli(["find-roots"], { env });
		assert.equal(refused.code, 10, `a resident of protocol ${PROTOCOL + 1} was not refused: ${refused.stderr}`);
		assert.match(refused.stderr, new RegExp(`^error resident_unavailable: .*protocol ${PROTOCOL + 1}`, "m"));
	} finally {
		foreign.close();
		await foreign.closed;
	}
}

async function cursorMotion(extraEnv) {
	const resident = await scriptedResident();
	try {
		return (await json(["doctor"], extraEnv)).config.config.cursor_motion;
	} finally {
		resident.close();
		await resident.closed;
	}
}

async function refusedMotion(extraEnv, pattern) {
	const result = await runCli(["status"], { env: { ...env, ...extraEnv } });
	assert.equal(result.code, 2, `an invalid cursor motion was not refused: ${result.stderr}`);
	assert.match(result.stderr, pattern);
}

async function cursorMotionChecks() {
	await fs.mkdir(path.join(home, ".config", "bcu"), { recursive: true });
	const config = path.join(home, ".config", "bcu", "config.json");
	await fs.writeFile(config, JSON.stringify({ cursor_motion: { style: "comet_swoop", timing: "fitts", effects: { glow: true } } }));
	assert.deepEqual(await cursorMotion({}), { style: "comet_swoop", timing: "fitts", effects: { trail: true, glow: true, magnet: false, ripple: true, squish: false } }, "the config file's cursor motion is not in effect");
	assert.deepEqual(
		await cursorMotion({ BCU_CURSOR_MOTION_STYLE: "magnetic", BCU_CURSOR_MOTION_EFFECTS: "ripple=off,squish=on" }),
		{ style: "magnetic", timing: "fitts", effects: { trail: false, glow: true, magnet: true, ripple: false, squish: true } },
		"BCU_CURSOR_MOTION_* did not override the config file field by field",
	);
	await refusedMotion({ BCU_CURSOR_MOTION_STYLE: "zigzag" }, /^error invalid_arguments: .*zigzag.*signature_arc, spring_settle, magnetic, comet_swoop, adaptive, classic/m);
	await refusedMotion({ BCU_CURSOR_MOTION_TIMING: "slow" }, /^error invalid_arguments: .*slow.*native, fitts, fixed/m);
	await refusedMotion({ BCU_CURSOR_MOTION_EFFECTS: "sparkle=on" }, /^error invalid_arguments: .*sparkle.*trail, glow, magnet, ripple, squish/m);
	await fs.writeFile(config, JSON.stringify({ cursor_motion: { effects: { trail: "maybe" } } }));
	await refusedMotion({}, /^error invalid_arguments: .*trail.*maybe/m);
	await fs.rm(path.join(home, ".config"), { recursive: true });
}

/** A throwaway bundle of this build, launched through LaunchServices like bcu.app. */
async function testBundle() {
	const app = path.join(root, "bcu-gate.app");
	await fs.mkdir(path.join(app, "Contents", "MacOS"), { recursive: true });
	await fs.copyFile(binary, path.join(app, "Contents", "MacOS", "bcu"));
	await fs.writeFile(path.join(app, "Contents", "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.sugeh.bcu.gate</string>
<key>CFBundleExecutable</key><string>bcu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
`);
	return app;
}

async function launchedChecks() {
	const bundleEnv = { ...env, BCU_APP_PATH: await testBundle(), BCU_IDLE_MS: "60000" };
	const cli = (args) => runCli([...args, "--json"], { env: bundleEnv });
	assert.deepEqual(JSON.parse((await cli(["status"])).stdout), { running: false });
	assert.deepEqual(JSON.parse((await cli(["stop"])).stdout), { stopped: true, alreadyStopped: true });
	assert(!existsSync(socketPath), "status or stop started a resident");

	const started = await Promise.all([cli(["find-roots"]), cli(["find-roots"]), cli(["find-roots"])]);
	for (const result of started) {
		assert.equal(result.code, 4, `a command on the ungranted bundle was not refused for its permissions: ${result.stderr}`);
		assert.match(result.stderr, /^error permission_missing: /m);
	}
	const status = JSON.parse((await cli(["status"])).stdout);
	assert.equal(status.running, true, "no resident is running after a command");
	const { stdout: parent } = await execFile("ps", ["-o", "ppid=,comm=", "-p", String(status.pid)]);
	assert.match(parent.trim(), /^1 .*bcu-gate\.app\/Contents\/MacOS\/bcu$/, `the resident was not launched from the bundle by LaunchServices: ${parent}`);
	const monitor = await monitorProcess(status.pid);
	assert.deepEqual(JSON.parse((await cli(["stop"])).stdout), { stopped: true, pid: status.pid });
	await withTimeout(monitor.exited, "the stopped resident to exit", 5_000);
	assert.deepEqual(JSON.parse((await cli(["status"])).stdout), { running: false });
}

try {
	await scriptedChecks();
	await launchedChecks();
	console.log("PASS scripted resident: status, doctor, stop, headless from env and config, cursor motion from config and env, protocol refused → launched resident: status and stop start nothing, a command starts it through LaunchServices and is refused for the missing grants, stop ends it");
} finally {
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(root, { recursive: true, force: true });
}
