#!/usr/bin/env node
// The CLI's side of the resident process, black box against the bcu executable built from
// this checkout. Against a scripted resident on the socket: status and stop report it,
// doctor shows its permissions and the local config, act-ui carries the headless setting of
// the environment and of the config file, the agent cursor motion is chosen in the config
// file and overridden per field by BCU_CURSOR_MOTION_*, and a config that is not valid JSON, has
// an unknown key or a wrong value, or a BCU_* variable with a wrong value, refuses every
// command with the allowed values.
// Against a test bundle of this build: status and stop never start a resident, a
// command starts one through LaunchServices that serves on the caller's socket, stop
// ends it, a client run from inside the bundle starts that bundle, --version reports the
// bundle's version, and a resident of another version than the bundle on disk (an upgrade
// replaced the app) is stopped and replaced by the next command. The bundle holds no grants, so the command is refused as permission_missing: the
// resident reads the grants without asking for them (only `bcu setup` asks).
import assert from "node:assert/strict";
import { execFile as execFileCallback } from "node:child_process";
import { existsSync } from "node:fs";
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
const SCRIPTED_VERSION = "1.2.3";
const env = { ...process.env, HOME: home, BCU_SOCKET_PATH: socketPath };

const DEFAULT_MOTION = { style: "signature_arc", timing: "native", effects: { trail: false, glow: true, magnet: false, ripple: true, squish: true } };

const ACT_RESULT = { stateId: "bbbbbbbb", baseStateId: "abcd1234", outcome: "worked", verification: { status: "none" }, delivery: "ax", changes: [] };

/** A resident that speaks the wire protocol from a script and records what it was asked. */
async function scriptedResident() {
	const requests = [];
	const server = net.createServer((socket) => {
		socket.write(`${JSON.stringify({ hello: status })}\n`);
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
	const status = { pid: process.pid, version: SCRIPTED_VERSION };
	function reply(message) {
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
	env.BCU_APP_PATH = await testBundle("scripted", SCRIPTED_VERSION);
	const resident = await scriptedResident();
	assert.equal(await text(["status"]), `resident running · pid ${process.pid} · version ${SCRIPTED_VERSION}\n`);
	assert.deepEqual(await json(["status"]), { running: true, pid: process.pid, version: SCRIPTED_VERSION });
	assert.equal(await text(["doctor"]), `resident ok · pid ${process.pid} · version ${SCRIPTED_VERSION}\npermissions: accessibility=true screenRecording=false\n`);
	const doctor = await json(["doctor"]);
	assert.deepEqual(doctor.permissions, { accessibility: true, screenRecording: false }, "doctor --json lost the resident's permissions");
	assert.deepEqual(doctor.config.config, { headless: false, cursor_overlay: true, cursor_motion: DEFAULT_MOTION }, "doctor --json does not report the default config");
	assert.equal(await text(["stop"]), `resident stopped · pid ${process.pid}\n`);
	await resident.closed;

	assert.equal(await headlessSent({}), false, "act-ui went headless with nothing asking for it");
	assert.equal(await headlessSent({ BCU_HEADLESS: "yes" }), true, "BCU_HEADLESS=yes did not make act-ui headless");
	await writeConfig({ headless: "on" });
	assert.equal(await headlessSent({}), true, "headless in the config file did not make act-ui headless");
	assert.equal(await headlessSent({ BCU_HEADLESS: "0" }), false, "BCU_HEADLESS=0 did not override the config file");

	await cursorMotionChecks();
	await refusedConfigChecks();
	await fs.rm(path.join(home, ".config"), { recursive: true });
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

async function writeConfig(value) {
	await fs.mkdir(path.join(home, ".config", "bcu"), { recursive: true });
	await fs.writeFile(path.join(home, ".config", "bcu", "config.json"), typeof value === "string" ? value : JSON.stringify(value));
}

async function cursorMotionChecks() {
	await writeConfig({ cursor_motion: { style: "comet_swoop", timing: "fitts", effects: { glow: true } } });
	assert.deepEqual(await cursorMotion({}), { style: "comet_swoop", timing: "fitts", effects: { trail: true, glow: true, magnet: false, ripple: true, squish: false } }, "the config file's cursor motion is not in effect");
	assert.deepEqual(
		await cursorMotion({ BCU_CURSOR_MOTION_STYLE: "magnetic", BCU_CURSOR_MOTION_EFFECTS: "ripple=off,squish=on" }),
		{ style: "magnetic", timing: "fitts", effects: { trail: false, glow: true, magnet: true, ripple: false, squish: true } },
		"BCU_CURSOR_MOTION_* did not override the config file field by field",
	);
}

/** Every wrong setting, in the file or the environment, refuses the command the same way. */
async function refusedConfigChecks() {
	const BOOLEAN = /true\/false, on\/off, yes\/no, 1\/0/;
	const cases = [
		[{}, "{ headless: true", /config\.json is not valid JSON/],
		[{}, { computer_use: { headless: true } }, /'computer_use' .*headless, cursor_overlay, cursor_motion/],
		[{}, { cursor_overlay: 2 }, new RegExp(`cursor_overlay .*2.*${BOOLEAN.source}`)],
		[{}, { cursor_motion: { effects: { trail: "maybe" } } }, new RegExp(`trail.*maybe.*${BOOLEAN.source}`)],
		[{ BCU_HEADLESS: "maybe" }, {}, new RegExp(`BCU_HEADLESS.*maybe.*${BOOLEAN.source}`)],
		[{ BCU_CURSOR_MOTION_STYLE: "zigzag" }, {}, /zigzag.*signature_arc, spring_settle, magnetic, comet_swoop, adaptive, classic/],
		[{ BCU_CURSOR_MOTION_TIMING: "slow" }, {}, /slow.*native, fitts, fixed/],
		[{ BCU_CURSOR_MOTION_EFFECTS: "sparkle=on" }, {}, /sparkle.*trail, glow, magnet, ripple, squish/],
	];
	for (const [extraEnv, config, pattern] of cases) {
		await writeConfig(config);
		const result = await runCli(["status"], { env: { ...env, ...extraEnv } });
		const subject = `${JSON.stringify(extraEnv)} with config ${JSON.stringify(config)}`;
		assert.equal(result.code, 2, `${subject} was not refused: ${result.stderr}`);
		assert.match(result.stderr, new RegExp(`^error invalid_arguments: .*${pattern.source}`, "m"), `${subject} was refused without naming the allowed values`);
	}
}

/** A throwaway bundle of this build at `version`, launched through LaunchServices like bcu.app. */
async function testBundle(name, version) {
	const app = path.join(root, `${name}.app`);
	await fs.mkdir(path.join(app, "Contents", "MacOS"), { recursive: true });
	await fs.copyFile(binary, path.join(app, "Contents", "MacOS", "bcu"));
	await fs.writeFile(path.join(app, "Contents", "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.sugeh.bcu.gate</string>
<key>CFBundleExecutable</key><string>bcu</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
`);
	return app;
}

async function launchedChecks() {
	const app = await testBundle("bcu-gate", "1.0.0");
	const bundleEnv = { ...env, BCU_APP_PATH: app, BCU_IDLE_MS: "60000" };
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
	assert.equal(status.version, "1.0.0", "the resident does not report its bundle's version");
	assert.equal((await runCli(["--version"], { env: bundleEnv })).stdout, "1.0.0\n");

	// An upgrade replaced the app on disk: the next command swaps the resident for the new one.
	await bumpVersion(app, "2.0.0");
	const old = await monitorProcess(status.pid);
	const refused = await cli(["find-roots"]);
	assert.match(refused.stderr, /^error permission_missing: /m);
	await withTimeout(old.exited, "the resident of the old version to exit", 5_000);
	const upgraded = JSON.parse((await cli(["status"])).stdout);
	assert.equal(upgraded.version, "2.0.0", "the command did not start the resident of the new version");
	assert.notEqual(upgraded.pid, status.pid);

	// A client inside the bundle starts its own app; BCU_APP_PATH is only an override.
	const { BCU_APP_PATH: _unused, ...inside } = bundleEnv;
	const installed = path.join(app, "Contents", "MacOS", "bcu");
	await execFile(installed, ["stop"], { env: inside });
	const own = await execFile(installed, ["find-roots"], { env: inside }).catch((failure) => failure);
	assert.match(own.stderr, /^error permission_missing: /m, "a client inside the bundle did not start the bundle's resident");
	const ownStatus = JSON.parse((await execFile(installed, ["status", "--json"], { env: inside })).stdout);
	const monitor = await monitorProcess(ownStatus.pid);
	assert.deepEqual(JSON.parse((await cli(["stop"])).stdout), { stopped: true, pid: ownStatus.pid });
	await withTimeout(monitor.exited, "the stopped resident to exit", 5_000);
	assert.deepEqual(JSON.parse((await cli(["status"])).stdout), { running: false });
}

async function bumpVersion(app, version) {
	const plist = path.join(app, "Contents", "Info.plist");
	await fs.writeFile(plist, (await fs.readFile(plist, "utf8")).replace(/(<key>CFBundleShortVersionString<\/key><string>)[^<]*/, `$1${version}`));
}

try {
	await scriptedChecks();
	await launchedChecks();
	console.log("PASS scripted resident: status, doctor, stop, headless from env and config, cursor motion from config and env, wrong config refused, launched resident: status and stop start nothing, a command starts it through LaunchServices and is refused for the missing grants, stop ends it");
} finally {
	await runCli(["stop"], { env }).catch(() => undefined);
	await fs.rm(root, { recursive: true, force: true });
}
