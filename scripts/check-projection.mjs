#!/usr/bin/env node
// The projection is the agent's whole view of a window: short roles, a closed capability
// vocabulary, folded entries, and a first view small enough to read.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { restoreOutline } from "../src/outline.ts";
import { CAPABILITIES, project, renderObservation } from "../src/projection.ts";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const capabilities = new Set(CAPABILITIES);

// Real outlines captured from a TextEdit document window and a Finder folder
// window; the budgets are half of the pre-projection rendering of the same two
// windows (1522 and 4700 bytes).
const cases = [
	{ name: "textEdit", fixture: "textedit-outline.json", budget: 760, app: "文本编辑", title: "未命名2" },
	{ name: "finder", fixture: "finder-outline.json", budget: 2340, app: "访达", title: "MacBook Pro" },
];

function lineCapabilities(text) {
	return [...text.matchAll(/\{([^}]*)\}/g)].flatMap((match) => match[1].split(",")).filter(Boolean);
}

for (const testCase of cases) {
	const outline = restoreOutline(JSON.parse(fs.readFileSync(path.join(root, "scripts", "fixtures", testCase.fixture), "utf8")));
	const projection = project(outline);
	const text = renderObservation({
		stateId: "11111111-2222-3333-4444-555555555555",
		root: { ref: "@r1", app: testCase.app, title: testCase.title },
		nodes: projection.nodes,
		shown: projection.shown,
		total: projection.total,
	});
	const bytes = Buffer.byteLength(text);

	assert(bytes <= testCase.budget, `${testCase.name} view is ${bytes} bytes, over the ${testCase.budget} budget:\n${text}`);
	assert(!/\bAX[A-Z]/.test(text), `${testCase.name} view leaks AX role or action names:\n${text}`);
	assert(!/_NS:/i.test(text), `${testCase.name} view leaks an internal identifier as a name:\n${text}`);
	assert(!/Target:0x0|Selector:/.test(text), `${testCase.name} view leaks a custom action description:\n${text}`);
	assert.equal(text.split("\n").length, projection.nodes.length + 1, `${testCase.name} view is not one line per node plus a header`);
	for (const capability of lineCapabilities(text)) {
		assert(capabilities.has(capability), `${testCase.name} view rendered capability '${capability}' outside the vocabulary`);
	}
	for (const node of projection.nodes) {
		assert(!/^ax/i.test(node.role) && node.role === node.role.toLowerCase(), `${testCase.name} projected role '${node.role}' is not a short word`);
		assert(!/^_ns:/i.test(node.name), `${testCase.name} projected an internal identifier as name '${node.name}'`);
		for (const capability of node.caps) assert(capabilities.has(capability), `${testCase.name} projected capability '${capability}' outside the vocabulary`);
	}
	assert.equal(projection.total, outline.nodes.length, `${testCase.name} did not report the full outline node count`);
	console.log(`PASS ${testCase.name} projection: ${bytes} bytes (budget ${testCase.budget}), ${projection.shown}/${projection.total} nodes`);
}

const finder = project(restoreOutline(JSON.parse(fs.readFileSync(path.join(root, "scripts", "fixtures", "finder-outline.json"), "utf8"))), { maxDepth: 8 });
const downloads = finder.nodes.find((node) => node.name === "下载");
assert(downloads, "Finder sidebar entry was not folded into a single named row");
assert.equal(downloads.role, "row", `Finder sidebar entry projected as '${downloads.role}'`);
assert.deepEqual(downloads.caps, ["open"], `Finder sidebar entry lost or invented capabilities: ${downloads.caps.join(",")}`);
console.log("PASS Finder sidebar rows fold into one line with merged capabilities");

// A menu separator is an unnamed, childless AXMenuItem that still answers AXPress;
// it is not something an agent can act on and only pads the menu view.
function menuNode(ref, title, children = []) {
	return { ref, wireRef: ref.slice(1), role: "AXMenuItem", subrole: "", identifier: "_NS:1", title, description: "", value: "", actions: ["AXCancel", "AXPress", "AXPick"], canPress: true, canFocus: false, canSetValue: false, canScroll: false, canIncrement: false, canDecrement: false, isTextInput: false, rect: { x: 0, y: 0, w: 200, h: 20 }, focused: false, offscreen: false, pictureOnly: false, truncated: false, text: [], children };
}
const menu = project(restoreOutline({
	lookId: "menu",
	root: { ...menuNode("@e1", ""), role: "AXMenu", actions: [], canPress: false, children: [menuNode("@e2", "新建"), menuNode("@e3", ""), menuNode("@e4", "关闭")] },
}), { maxDepth: 8 });
assert.deepEqual(menu.nodes.map((node) => node.ref), ["@e1", "@e2", "@e4"], `menu separator survived projection: ${menu.nodes.map((node) => node.ref).join(",")}`);
console.log("PASS menu separators are dropped from the view");
