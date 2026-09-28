#!/usr/bin/env node
// The projection is the agent's whole view of a window: short roles, a closed capability
// vocabulary, folded entries, and a first view small enough to read. A capability is a
// promise: web content and menu items do not advertise the context menu every node of
// theirs answers, and a web scroller advertises the scroll that act-ui performs on it.
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

// Every menu item and menu bar item answers AXPick and AXShowMenu; pressing it is all it offers.
const menuBar = project(restoreOutline({
	lookId: "menubar",
	root: {
		...menuNode("@e1", ""),
		role: "AXMenuBar",
		actions: [],
		canPress: false,
		children: [{ ...menuNode("@e2", "文件"), role: "AXMenuBarItem", actions: ["AXCancel", "AXPress", "AXPick", "AXShowMenu"], children: [menuNode("@e3", "保存")] }],
	},
}), { maxDepth: 8 });
for (const ref of ["@e2", "@e3"]) {
	const item = menuBar.nodes.find((node) => node.ref === ref);
	assert.deepEqual(item?.caps, ["press"], `menu item ${ref} advertises ${JSON.stringify(item?.caps)} instead of press alone`);
}
console.log("PASS menu items and menu bar items advertise press alone");

// A real Chrome window rendering the page of scripts/check-web-background.mjs. Chromium
// answers AXShowMenu on every web node, and the page's scroll area exposes no scroll action.
const chromeOutline = restoreOutline(JSON.parse(fs.readFileSync(path.join(root, "scripts", "fixtures", "chrome-outline.json"), "utf8")));
const chrome = project(chromeOutline, { maxDepth: 12, maxNodes: 1_000 });
const inWebContent = (ref) => {
	for (let node = chromeOutline.nodes.find((candidate) => candidate.ref === ref); node; node = node.parent) {
		if (node.role === "AXWebArea") return true;
	}
	return false;
};
const webNodes = chrome.nodes.filter((node) => inWebContent(node.ref));
assert(webNodes.length >= 8, `the Chrome fixture projected only ${webNodes.length} web nodes`);
for (const node of webNodes) {
	assert(!node.caps.includes("menu") && !node.owners?.menu, `web node ${node.ref} ${node.role} ${JSON.stringify(node.name)} advertises a context menu: {${node.caps}} ${JSON.stringify(node.owners ?? {})}`);
}
const browserButton = chrome.nodes.find((node) => node.name === "New Tab");
assert.deepEqual(browserButton?.caps, ["press", "menu"], `the browser's own New Tab button lost its context menu: ${JSON.stringify(browserButton?.caps)}`);
console.log("PASS web content drops the context menu Chromium offers everywhere; the browser's own controls keep it");

const scrollers = webNodes.filter((node) => node.caps.includes("scroll"));
assert.deepEqual(scrollers.map((node) => node.name), ["Scroll area"], `web scroll capability went to ${JSON.stringify(scrollers.map((node) => `${node.ref} ${node.role} ${node.name}`))} instead of the page's one scroll area`);
console.log("PASS the web scroll area advertises scroll, and no other web node does");

// AppKit hands out developer strings where a label belongs: private names, build-time
// constants and Objective-C selectors. None of them is something an agent can read or say.
const internalNames = ["_SC_SEARCH_FIELD", "SC_SEARCH_FIELD", "searchFieldAction:", "_NS:24", "insertText:replacementRange:"];
const internals = project(restoreOutline({
	lookId: "internal",
	root: {
		...menuNode("@e1", ""),
		role: "AXMenu",
		actions: [],
		canPress: false,
		children: [
			...internalNames.map((name, index) => ({ ...menuNode(`@e${index + 2}`, name), children: [] })),
			{ ...menuNode(`@e${internalNames.length + 2}`, "新建"), children: [] },
			{ ...menuNode(`@e${internalNames.length + 3}`, "File:"), children: [] },
		],
	},
}), { maxDepth: 8 });
for (const name of internalNames) {
	assert(!internals.nodes.some((node) => node.name === name), `projection presented the internal string '${name}' as a name`);
}
assert(internals.nodes.some((node) => node.name === "新建") && internals.nodes.some((node) => node.name === "File:"), "the internal-name filter swallowed a real label");
console.log("PASS developer strings never stand in for a name");
