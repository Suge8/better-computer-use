#!/usr/bin/env node
// An observation of a real window, through the public CLI, holds the contract agents rely
// on: root discovery over the whole desktop is bounded and survives a caller that gives up
// halfway, an observation with an image keeps every element inside the image, OCR adds no
// line the window's own accessibility text already says, refs and states that do not exist
// are refused, and the view stays inside the agent vocabulary. The subject is a TextEdit
// window this gate opens itself, so the verdict never depends on what the desktop shows.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { appPath, launchTextEdit, makeTemporaryRoot, monitorProcess, request, residentEnvironment, runCli, stopTextEdit, waitForAxWindow, withTimeout } from "./lib/harness.mjs";

/** The only capability words the view may show; see Capability in Sources/BCUCore/Projection.swift. */
const CAPABILITIES = ["press", "toggle", "setText", "typeText", "menu", "open", "expand", "scroll", "increment", "decrement", "raise"];
/** Several lines of plain text the text area exposes, so OCR has lines it must not repeat. */
const FIXTURE_TEXT = "bcu live observe fixture\nsecond line of fixture text\nthird line of fixture text\n";

const results = [];

function check(name, fn) {
	try {
		fn();
		results.push([name, true]);
		console.log(`PASS ${name}`);
	} catch (error) {
		results.push([name, false]);
		process.exitCode = 1;
		console.error(`FAIL ${name}: ${error.message}`);
	}
}

function assert(condition, message) {
	if (!condition) throw new Error(message);
}

function walk(node, visit) {
	visit(node);
	for (const child of node.children ?? []) walk(child, visit);
}

async function refusal(args, input, env) {
	const result = await runCli([...args, "--json"], { input, env });
	return result.code === 0 ? "success" : result.stderr.split(":")[0].replace(/^error /, "");
}

async function liveChecks() {
	if (process.env.BCU_LIVE !== "1") {
		console.log("SKIP live observe checks (set BCU_LIVE=1)");
		return;
	}
	const directory = await makeTemporaryRoot("observe-live");
	const env = residentEnvironment(path.join(directory, "resident.sock"), 30_000);
	const title = `bcu-observe-live-${randomUUID()}`;
	let pid;
	let monitor;
	try {
		const started = Date.now();
		const broad = await request("find-roots", {}, env);
		const broadMs = Date.now() - started;
		const resident = (await request("status", {}, env)).pid;
		check("broad root discovery is bounded", () => {
			assert(Array.isArray(broad.roots), "find-roots returned no roots array");
			assert(broadMs < 10_000, `find-roots over the whole desktop took ${broadMs}ms`);
		});
		const abandoned = spawn(process.env.BCU_BIN ?? path.join(appPath, "Contents", "MacOS", "bcu"), ["find-roots"], { env, stdio: "ignore" });
		abandoned.kill("SIGKILL");
		await withTimeout(new Promise((resolve) => abandoned.once("exit", resolve)), "the abandoned find-roots to exit", 5_000);
		await request("find-roots", {}, env);
		const after = (await request("status", {}, env)).pid;
		check("a caller that gives up leaves the resident serving", () => assert(after === resident, `the resident changed from pid ${resident} to ${after}`));

		await fs.writeFile(path.join(directory, `${title}.txt`), FIXTURE_TEXT);
		pid = await launchTextEdit(path.join(directory, `${title}.txt`));
		monitor = await monitorProcess(pid);
		await waitForAxWindow(pid, monitor.exited, title);
		const window = (await request("find-roots", { pid, kind: "window" }, env)).roots.find((root) => root.title.startsWith(title));
		assert(window, `the fixture window ${title} is not a root`);
		const observed = await request("observe-ui", { root: window.ref, image: "always", readText: "always" }, env);
		const outline = (await request("inspect-ui", { stateId: observed.stateId, ref: observed.nodes[0].ref }, env)).node;
		check("the observation carries its image", () => {
			assert(observed.image && observed.image.width > 0 && observed.image.height > 0, `no image: ${JSON.stringify(observed.image)}`);
		});
		check("rects within image", () => {
			walk(outline, (node) => {
				const rect = node.rect;
				if (!rect) return;
				assert(rect.x >= 0 && rect.y >= 0 && rect.x + rect.w <= observed.image.width + 0.01 && rect.y + rect.h <= observed.image.height + 0.01, `rect out of bounds ${JSON.stringify(rect)}`);
			});
		});
		check("OCR repeats nothing Accessibility already says", () => {
			// OCR may change letter case, so lines compare the way the dedupe does.
			const plain = (text) => text.toLowerCase().replace(/\s+/g, "");
			const read = [];
			walk(outline, (node) => { if (node.pictureOnly) read.push(plain(node.title)); });
			const repeated = FIXTURE_TEXT.split("\n").filter((line) => line && read.includes(plain(line)));
			assert(repeated.length === 0, `OCR repeated text the text area already exposes: ${JSON.stringify(repeated)}`);
		});
		const press = JSON.stringify([{ action: "press", ref: "@e99999" }]);
		const unknownRef = await refusal(["act-ui", "--state", observed.stateId, "-"], press, env);
		const unknownState = await refusal(["act-ui", "--state", "00000000", "-"], press, env);
		check("refs and states that do not exist are refused", () => {
			assert(unknownRef === "element_not_found", `a ref outside the state gave ${unknownRef}`);
			assert(unknownState === "stale_state", `an unknown state gave ${unknownState}`);
		});
		const text = await runCli(["observe-ui", "--root", window.ref], { env });
		check("the view stays inside the agent vocabulary", () => {
			for (const node of observed.nodes) {
				assert(!/^ax/i.test(node.role), `projected role kept its AX prefix: ${node.role}`);
				for (const capability of node.caps) assert(CAPABILITIES.includes(capability), `projected capability outside the vocabulary: ${capability}`);
			}
			assert(text.code === 0 && !/\bAX[A-Z]/.test(text.stdout), `the text view leaks raw accessibility names:\n${text.stdout}`);
			const shown = new Set(observed.nodes.map((node) => node.ref));
			const folded = observed.nodes.some((node) => node.hidden);
			walk(outline, (node) => {
				if (node.focused && node.canFocus) assert(shown.has(node.ref) || folded, `focused ref ${node.ref} was neither shown nor folded`);
			});
		});
	} catch (error) {
		results.push(["live", false]);
		process.exitCode = 1;
		console.error(`FAIL live observe ${error.message}`);
	} finally {
		if (pid) await stopTextEdit(pid, monitor);
		await runCli(["stop"], { env }).catch(() => undefined);
		await fs.rm(directory, { recursive: true, force: true });
	}
}

await liveChecks();
if (results.some(([, ok]) => !ok)) process.exit(1);
