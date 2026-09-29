#!/usr/bin/env node
// One-shot golden generator for step 1 of docs/adr/0002-single-swift-process.md: runs the
// current TS implementation on the outline fixtures and the pure cases of check-projection,
// check-contract, check-cli-errors and check-runtime, and writes the exact outputs to
// Tests/BCUCoreTests/Golden/. The Swift port must reproduce every output byte for byte.
// Run once, commit the output; deleted together with the TS sources in step 2.
//
// Pure functions are called directly. What only the CLI or the Broker composes — argument
// parsing, result rendering, search/expand/inspect over a saved state, and the element an
// action is delivered to — runs through the real CLI, against a recording fake Broker or
// the real Broker with a scripted helper.
import { once } from "node:events";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { canRetryInForeground, outcomeAfterCheck, outcomeAfterObservedValues, prepareAction, validateActions } from "../src/actions.ts";
import { BcuError, formatCliError, normalizeCliError } from "../src/errors.ts";
import { HELPER_PROTOCOL_VERSION } from "../src/macos/helper.ts";
import { HELPER_ARCHITECTURE_VERSION, REQUIRED_HELPER_INVARIANTS } from "../src/macos/protocol.ts";
import { ensurePointIsInLookImage, outlineNodeCenter, successorView, UNFOLDED } from "../src/observe.ts";
import { graftScopedOutline, nodeByRef, parseLookResponse, restoreOutline, serializeOutline } from "../src/outline.ts";
import { project, renderNodes, renderObservation } from "../src/projection.ts";
import { changesBetween, renderChanges, renderOffscreen, stabilizeRefs } from "../src/view.ts";
import { brokerEnvironment, buildBundle, makeTemporaryRoot, repoRoot, runCli, spawnBroker, withTimeout } from "./lib/harness.mjs";

const GOLDEN = path.join(repoRoot, "Tests", "BCUCoreTests", "Golden");
const FIXTURE_NAMES = ["textedit-outline.json", "finder-outline.json", "chrome-outline.json", "editor-outline.json"];
const fixtures = Object.fromEntries(FIXTURE_NAMES.map((name) => [name, JSON.parse(fs.readFileSync(path.join(repoRoot, "scripts", "fixtures", name), "utf8"))]));

/** Inputs pass through JSON first, so TS and Swift start from the same bytes. */
const roundtrip = (value) => JSON.parse(JSON.stringify(value));

/** Stable key order for internal shapes (parsed params, prepared actions) whose order carries no meaning. */
function canonical(value) {
	if (Array.isArray(value)) return value.map(canonical);
	if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().filter((key) => value[key] !== undefined).map((key) => [key, canonical(value[key])]));
	return value;
}
const canonicalJson = (value) => JSON.stringify(canonical(value));

function formatted(error) {
	const normalized = normalizeCliError(error);
	return { stderr: formatCliError(normalized), exitCode: normalized.exitCode };
}

// ---- outlines ----

function toWireNode(node) {
	return { ...node, ref: node.wireRef, wireRef: undefined, children: node.children.map(toWireNode) };
}

const WINDOW = { windowId: 1, framePoints: { x: 0, y: 0, w: 800, h: 600 }, scaleFactor: 1, isModal: false, role: "AXWindow", subrole: "AXStandardWindow" };

function parseWire(lookId, wireRoot) {
	return parseLookResponse({ lookId, capturedAt: 0, window: WINDOW, outline: wireRoot, timings: {} }).parsedOutline;
}

/** `saved` keeps the refs of a saved state; `fresh` numbers a new look breadth-first. */
function loadOutline(input) {
	const serialized = roundtrip(input.fixture ? fixtures[input.fixture] : input.outline);
	if (input.numbering === "saved") return restoreOutline(serialized);
	return parseWire(serialized.lookId, toWireNode(serialized.root));
}

/** An outline the helper would send, as the saved state the Swift side restores. */
function inline(lookId, root) {
	return { outline: roundtrip(serializeOutline(parseWire(lookId, root))), numbering: "saved" };
}

const fresh = (fixture) => ({ fixture, numbering: "fresh" });
const saved = (fixture) => ({ fixture, numbering: "saved" });
const windowRoot = (children, extra = {}) => ({ ref: "window", role: "AXWindow", subrole: "AXStandardWindow", title: "Fixture", children, ...extra });

// ---- golden files ----

const files = {};
function add(file, name, op, input, output) {
	(files[file] ??= []).push({ name, op, input: roundtrip(input), output });
}

function catching(run) {
	try {
		return run();
	} catch (error) {
		return formatted(error);
	}
}

// outline.json: numbering, graft and ref stability.
for (const fixture of FIXTURE_NAMES) {
	add("outline", `build ${fixture}`, "build", { outline: fresh(fixture) }, { json: JSON.stringify(serializeOutline(loadOutline(fresh(fixture)))) });
}

const runtimeBase = inline("look-1", windowRoot([
	{ ref: "toolbar", role: "AXToolbar", title: "Toolbar" },
	{ ref: "editor", role: "AXTextArea", value: "", canSetValue: true, isTextInput: true },
]));
const runtimeNext = inline("look-2", windowRoot([
	{ ref: "inserted", role: "AXStaticText", value: "Status" },
	{ ref: "toolbar", role: "AXToolbar", title: "Toolbar" },
	{ ref: "editor", role: "AXTextArea", value: "hello", canSetValue: true, isTextInput: true },
]));
const runtimeRegenerated = inline("look-3", windowRoot([
	{ ref: "toolbar-new", role: "AXToolbar", title: "Toolbar" },
	{ ref: "editor-new", role: "AXTextArea", value: "updated", canSetValue: true, isTextInput: true },
]));
/** Two identical siblings: structural identity is ambiguous, so they get new refs. */
const twinsBase = inline("look-twins-1", windowRoot([
	{ ref: "a1", role: "AXButton", title: "Same" },
	{ ref: "a2", role: "AXButton", title: "Same" },
	{ ref: "u", role: "AXButton", title: "Unique" },
]));
const twinsNext = inline("look-twins-2", windowRoot([
	{ ref: "b1", role: "AXButton", title: "Same" },
	{ ref: "b2", role: "AXButton", title: "Same" },
	{ ref: "u2", role: "AXButton", title: "Unique" },
	{ ref: "n", role: "AXButton", title: "New" },
]));

function stabilized(base, next) {
	const nextOutline = loadOutline(next);
	stabilizeRefs(loadOutline(base), nextOutline);
	return nextOutline;
}
for (const [name, base, next] of [
	["native refs held", runtimeBase, runtimeNext],
	["native refs regenerated", runtimeBase, runtimeRegenerated],
	["ambiguous structural twins", twinsBase, twinsNext],
	["textedit against itself", fresh("textedit-outline.json"), fresh("textedit-outline.json")],
]) {
	add("outline", `stabilize ${name}`, "stabilize", { base, next }, { json: JSON.stringify(serializeOutline(stabilized(base, next))) });
}

const graftBase = inline("look-graft", windowRoot([
	{ ref: "toolbar", role: "AXToolbar", title: "Toolbar" },
	{ ref: "list", role: "AXList", title: "Files", truncated: true, children: [{ ref: "row-0", role: "AXRow", title: "zero", rect: { x: 1, y: 2, w: 3, h: 4 } }] },
]));
const graftScoped = inline("look-graft-scope", { ref: "list", role: "AXList", title: "Files", rect: { x: 5, y: 5, w: 50, h: 50 }, children: [
	{ ref: "row-1", role: "AXRow", title: "one", rect: { x: 5, y: 5, w: 50, h: 10 }, scrollExtent: { seen: 1, total: 4 } },
	{ ref: "row-0", role: "AXRow", title: "zero again", children: [{ ref: "cell", role: "AXCell", value: "c" }] },
] });
{
	const outline = loadOutline(graftBase);
	const target = outline.wireRefToRef.get("list");
	const grafted = graftScopedOutline(outline, target, loadOutline(graftScoped));
	add("outline", "graft keeps refs and appends new ones", "graft", { outline: graftBase, target, scoped: graftScoped }, { json: JSON.stringify({ ref: grafted.ref, outline: serializeOutline(outline) }) });
	add("outline", "graft on a missing target", "graft", { outline: graftBase, target: "@e99", scoped: graftScoped }, catching(() => graftScopedOutline(loadOutline(graftBase), "@e99", loadOutline(graftScoped))));
}

// projection.json: the agent view of the three real windows and the hand-built edge cases.
const HEADERS = {
	"textedit-outline.json": { app: "文本编辑", title: "未命名2" },
	"finder-outline.json": { app: "访达", title: "MacBook Pro" },
	"chrome-outline.json": { app: "Google Chrome", title: "bcu web background" },
	"editor-outline.json": { app: "Google Chrome", title: "bcu editor fixture - Google Chrome" },
};

function projectionCase(name, input, options = {}, header) {
	const outline = loadOutline(input);
	const { from, ...rest } = options;
	const projection = project(outline, { ...rest, from: from ? nodeByRef(outline, from) : undefined });
	const text = header
		? renderObservation({ stateId: header.stateId, root: header.root, nodes: projection.nodes, shown: projection.shown, total: projection.total })
		: renderNodes(projection.nodes);
	const json = JSON.stringify({ nodes: projection.nodes, shown: projection.shown, total: projection.total, truncated: projection.truncated });
	add("projection", name, "project", { outline: input, options, header }, { json, text });
}

for (const fixture of FIXTURE_NAMES) {
	for (const numbering of ["saved", "fresh"]) {
		projectionCase(`${fixture} ${numbering} first view`, { fixture, numbering }, {}, { stateId: "1a2b3c4d", root: { ref: "@r1", ...HEADERS[fixture] } });
	}
	projectionCase(`${fixture} unfolded`, saved(fixture), { maxDepth: UNFOLDED.maxDepth, maxNodes: UNFOLDED.maxNodes });
}
projectionCase("finder depth 8", saved("finder-outline.json"), { maxDepth: 8 });
projectionCase("finder depth 2 capped at 10 nodes", saved("finder-outline.json"), { maxDepth: 2, maxNodes: 10 });
projectionCase("finder unfold one folded ref", saved("finder-outline.json"), { maxDepth: 1, unfold: ["@e2"] });
projectionCase("chrome depth 12", saved("chrome-outline.json"), { maxDepth: 12, maxNodes: 1_000 });
projectionCase("textedit from a subtree", fresh("textedit-outline.json"), { maxDepth: 3, from: "@e3" });
projectionCase("header without a root ref", fresh("textedit-outline.json"), {}, { stateId: "00000000", root: { app: "TextEdit", title: "" } });

function menuItem(ref, title, extra = {}) {
	return { ref, role: "AXMenuItem", identifier: "_NS:1", title, actions: ["AXCancel", "AXPress", "AXPick"], canPress: true, rect: { x: 0, y: 0, w: 200, h: 20 }, ...extra };
}
projectionCase("menu separators drop", inline("menu", { ref: "menu", role: "AXMenu", children: [menuItem("new", "新建"), menuItem("sep", ""), menuItem("close", "关闭")] }), { maxDepth: 8 });
projectionCase("menu bar items press only", inline("menubar", { ref: "bar", role: "AXMenuBar", children: [
	{ ...menuItem("file", "文件"), role: "AXMenuBarItem", actions: ["AXCancel", "AXPress", "AXPick", "AXShowMenu"], children: [menuItem("save", "保存")] },
] }), { maxDepth: 8 });
const INTERNAL_NAMES = ["_SC_SEARCH_FIELD", "SC_SEARCH_FIELD", "searchFieldAction:", "_NS:24", "insertText:replacementRange:", "NSTextViewIdentifier", "FooIdentifier.3"];
projectionCase("developer strings never name a node", inline("internal", { ref: "menu", role: "AXMenu", children: [
	...INTERNAL_NAMES.map((name, index) => menuItem(`i${index}`, name)),
	menuItem("real", "新建"),
	menuItem("colon", "File:"),
	{ ref: "idname", role: "AXButton", identifier: "saveButton", actions: ["AXPress"], canPress: true },
	{ ref: "idnoise", role: "AXButton", identifier: "_NS:9", actions: ["AXPress"], canPress: true },
] }), { maxDepth: 8 });
projectionCase("text escaping and truncation", inline("escape", windowRoot([
	{ ref: "quote", role: "AXButton", title: "He said \"hi\"\n\tthen\u0001left 🎉 é\\", actions: ["AXPress"], canPress: true },
	{ ref: "long", role: "AXStaticText", value: `${"界面".repeat(70)}  tail` },
	{ ref: "value", role: "AXTextField", title: "Name", value: `${"v ".repeat(100)}end`, canSetValue: true, isTextInput: true, focused: true, canFocus: true },
	{ ref: "spaces", role: "AXButton", title: "\u00a0 wide\u3000gap\u2028line\ufeff ", actions: ["AXPress"], canPress: true },
	{ ref: "emoji", role: "AXStaticText", value: `${"a".repeat(119)}🎉🎉` },
])), { maxDepth: 8 });
projectionCase("capabilities and state words", inline("caps", windowRoot([
	{ ref: "check", role: "AXCheckBox", title: "Bold", value: "1", actions: ["AXPress"], canPress: true },
	{ ref: "switch", role: "AXCheckBox", subrole: "AXSwitch", title: "Wi-Fi", canSetValue: true },
	{ ref: "slider", role: "AXSlider", title: "Volume", value: "0.5", actions: ["AXIncrement", "AXDecrement"], canIncrement: true, canDecrement: true },
	{ ref: "list", role: "AXScrollArea", canScroll: true, scrollExtent: { seen: 3, total: 10 }, truncated: true, offscreen: true, children: [
		{ ref: "row", role: "AXRow", subrole: "AXOutlineRow", actions: ["AXOpen", "AXShowMenu", "AXExpand", "AXRaise", "AXCustom"], children: [{ ref: "rowtext", role: "AXStaticText", value: "Row one" }, { ref: "rowimg", role: "AXImage", description: "icon" }] },
		{ ref: "disc", role: "AXDisclosureTriangle", actions: ["AXPress"], canPress: true },
	] },
	{ ref: "ocr", role: "AXStaticText", value: "屏幕文字", pictureOnly: true },
	{ ref: "wrapper", role: "AXGroup", children: [{ ref: "inner", role: "AXButton", title: "Inner", actions: ["AXPress"], canPress: true }] },
	{ ref: "cellwrap", role: "AXButton", actions: ["AXPress"], canPress: true, children: [{ ref: "cell", role: "AXCell", actions: ["AXShowMenu"], children: [{ ref: "celltext", role: "AXStaticText", value: "Cell" }] }] },
	{ ref: "unnamedlink", role: "AXLink", children: [{ ref: "lgroup", role: "AXGroup", title: "Grouped", actions: ["AXPress"], canPress: true }] },
	{ ref: "bar", role: "AXScrollBar", actions: ["AXIncrement"], canIncrement: true },
	{ ref: "sheet", role: "AXSheet", children: [{ ref: "deep", role: "AXGroup", children: [{ ref: "deeper", role: "AXGroup", children: [{ ref: "ok", role: "AXButton", title: "OK", actions: ["AXPress"], canPress: true }] }] }] },
])), {}, { stateId: "cafebabe", root: { ref: "@r7", app: "Fixture", title: "Fixture" } });
projectionCase("web content capabilities", inline("web", windowRoot([
	{ ref: "tab", role: "AXButton", title: "New Tab", actions: ["AXPress", "AXShowMenu"], canPress: true },
	{ ref: "web", role: "AXWebArea", title: "Page", canFocus: true, actions: ["AXShowMenu"], children: [
		{ ref: "scroller", role: "AXGroup", title: "Scroll area", canFocus: true, actions: ["AXShowMenu"] },
		{ ref: "field", role: "AXTextField", title: "Query", canFocus: true, canSetValue: true, isTextInput: true, actions: ["AXShowMenu"] },
		{ ref: "go", role: "AXButton", title: "Go", canPress: true, canFocus: true, actions: ["AXPress", "AXShowMenu"] },
	] },
])), { maxDepth: 8 });

// view.json: successor diffs and their rendering.
function changesCase(name, base, next, { visible, baseVisible, menusOpenedByBcu, stabilize = false } = {}) {
	const baseOutline = loadOutline(base);
	const nextOutline = loadOutline(next);
	if (stabilize) stabilizeRefs(baseOutline, nextOutline);
	const transition = changesBetween(project(baseOutline, UNFOLDED).nodes, project(nextOutline, UNFOLDED).nodes, visible ? new Set(visible) : undefined, {
		baseVisible: baseVisible ? new Set(baseVisible) : undefined,
		menusOpenedByBcu,
	});
	add("view", name, "changes", { base, next, visible, baseVisible, menusOpenedByBcu, stabilize }, {
		json: JSON.stringify(transition),
		text: renderChanges(transition.changes),
		offscreen: renderOffscreen(transition.offscreen),
	});
}

function successorCase(name, base, next, menusOpenedByBcu) {
	const baseOutline = loadOutline(base);
	const nextOutline = loadOutline(next);
	stabilizeRefs(baseOutline, nextOutline);
	const view = successorView(baseOutline, nextOutline, { menusOpenedByBcu });
	add("view", name, "successor", { base, next, menusOpenedByBcu }, { json: JSON.stringify(view) });
	return view;
}

changesCase("runtime successor diff", runtimeBase, runtimeNext, { stabilize: true });
changesCase("runtime regenerated refs", runtimeBase, runtimeRegenerated, { stabilize: true });
const visibilityBase = inline("look-vis-1", windowRoot([
	{ ref: "hidden-item", role: "AXMenuItem", title: "Far", actions: ["AXPress"], canPress: true, offscreen: true },
	{ ref: "shown-item", role: "AXMenuItem", title: "Near", actions: ["AXPress"], canPress: true },
]));
const visibilityNext = inline("look-vis-2", windowRoot([
	{ ref: "hidden-item", role: "AXMenuItem", title: "Far", actions: ["AXPress"], canPress: true },
	{ ref: "shown-item", role: "AXMenuItem", title: "Near", actions: ["AXPress"], canPress: true, focused: true, canFocus: true },
]));
changesCase("invisible visibility flip is quiet", visibilityBase, visibilityNext, { visible: ["@e3"] });
changesCase("visible visibility flip is named", visibilityBase, visibilityNext, { visible: ["@e2", "@e3"] });
changesCase("every field and state word", inline("words-1", windowRoot([
	{ ref: "a", role: "AXButton", title: "Old", actions: ["AXPress"], canPress: true },
	{ ref: "b", role: "AXScrollArea", title: "List", canScroll: true, scrollExtent: { seen: 3, total: 10 }, truncated: true },
	{ ref: "c", role: "AXTextField", title: "Field", value: "x", canSetValue: true, isTextInput: true, focused: true, canFocus: true },
	{ ref: "d", role: "AXStaticText", value: "gone soon" },
	{ ref: "e", role: "AXScrollArea", title: "Other", canScroll: true, offscreen: true },
])), inline("words-2", windowRoot([
	{ ref: "a", role: "AXCheckBox", title: "New", value: "1", canSetValue: true },
	{ ref: "b", role: "AXScrollArea", title: "List", canScroll: true, scrollExtent: { seen: 10, total: 10 } },
	{ ref: "c", role: "AXTextField", title: "Field", canSetValue: true, isTextInput: true, canFocus: true },
	{ ref: "e", role: "AXScrollArea", title: "Other", canScroll: true, scrollExtent: { seen: 1, total: 5 } },
	{ ref: "f", role: "AXButton", title: "Added", actions: ["AXPress"], canPress: true, children: [{ ref: "g", role: "AXButton", title: "Child", actions: ["AXPress"], canPress: true }] },
])));

// The TextEdit window with its editor changed, and with a batch of offscreen menu items
// grown under a node the first view folds, as the scripted app of check-contract does.
const texteditWire = toWireNode(fixtures["textedit-outline.json"].root);
function mutatedTextEdit(value, noiseItems) {
	const base = loadOutline(fresh("textedit-outline.json"));
	const folded = project(base).nodes.find((node) => node.hidden);
	const noiseParent = nodeByRef(base, folded.ref).wireRef;
	const editorWire = base.nodes.find((node) => node.role === "AXTextArea").wireRef;
	const visit = (node) => ({
		...node,
		value: node.ref === editorWire ? value : node.value,
		children: [
			...node.children.map(visit),
			...(noiseItems && node.ref === noiseParent ? Array.from({ length: noiseItems }, (_, index) => ({ ref: `noise-${index}`, role: "AXMenuItem", title: `菜单项 ${index}`, actions: ["AXPress"], canPress: true, offscreen: true, children: [] })) : []),
		],
	});
	return { outline: roundtrip(serializeOutline(parseWire("look-mutated", visit(texteditWire)))), numbering: "saved" };
}
const typed = mutatedTextEdit("typed", 0);
const noisy = mutatedTextEdit("noise on", 30);
const quiet = mutatedTextEdit("noise off", 0);
changesCase("offscreen noise counted outside the view", fresh("textedit-outline.json"), noisy, { stabilize: true, visible: [], baseVisible: [] });

const views = {};
views.typed = successorCase("textedit editor value", fresh("textedit-outline.json"), typed);
views.noisy = successorCase("textedit offscreen noise grows", fresh("textedit-outline.json"), noisy);
successorCase("textedit offscreen noise drops", noisy, quiet);
views.unchanged = successorCase("textedit unchanged", fresh("textedit-outline.json"), fresh("textedit-outline.json"));
views.full = successorCase("another window is a full view", fresh("textedit-outline.json"), fresh("finder-outline.json"));
const menuBase = inline("menu-1", { ref: "bar", role: "AXMenuBar", children: [
	{ ref: "file", role: "AXMenuBarItem", title: "文件", actions: ["AXPress"], canPress: true, children: [{ ref: "menu", role: "AXMenu", children: [menuItem("old", "旧菜单")] }] },
] });
const menuNext = inline("menu-2", { ref: "bar", role: "AXMenuBar", children: [
	{ ref: "file", role: "AXMenuBarItem", title: "文件", value: "open", actions: ["AXPress"], canPress: true, children: [{ ref: "menu2", role: "AXMenu", children: [menuItem("search", "搜索"), menuItem("new", "新菜单")] }] },
] });
views.menus = successorCase("menu tree bcu opened is counted", menuBase, menuNext, true);
successorCase("menu tree without bcu opening menus", menuBase, menuNext, false);
changesCase("large change needs the full view", inline("big-1", windowRoot(Array.from({ length: 30 }, (_, index) => ({ ref: `k${index}`, role: "AXButton", title: `Keep ${index}`, actions: ["AXPress"], canPress: true })))),
	inline("big-2", windowRoot(Array.from({ length: 30 }, (_, index) => ({ ref: `k${index}`, role: "AXButton", title: `Keep ${index}`, value: `${index}`, actions: ["AXPress"], canPress: true })))), { stabilize: true });

// actions.json: the act-ui boundary and action preparation.
function validateCase(name, actions) {
	const output = catching(() => {
		validateActions(actions);
		return { ok: canonicalJson(actions) };
	});
	add("actions", name, "validate", { actions }, output);
}
for (const [name, action] of [
	["numeric ref", { action: "click", ref: 123 }],
	["empty ref", { action: "click", ref: "" }],
	["blank ref", { action: "click", ref: " \t" }],
	["invalid button", { action: "click", ref: "@e1", button: "banana" }],
	["invalid clickCount type", { action: "click", ref: "@e1", clickCount: "many" }],
	["invalid clickCount range", { action: "click", ref: "@e1", clickCount: 4 }],
	["fractional clickCount", { action: "click", ref: "@e1", clickCount: 1.5 }],
	["ignored doubleClick count", { action: "doubleClick", ref: "@e1", clickCount: 2 }],
	["invalid scrollY", { action: "scroll", ref: "@e1", scrollY: "abc" }],
	["invalid scroll range", { action: "scroll", ref: "@e1", scrollX: 10_001 }],
	["invalid wait ms", { action: "wait", ms: "soon" }],
	["invalid wait range", { action: "wait", ms: 60_001 }],
	["negative wait", { action: "wait", ms: -1 }],
	["partial coordinates", { action: "click", x: 10 }],
	["mixed targets", { action: "click", ref: "@e1", x: 10, y: 10 }],
	["missing keys", { action: "keypress" }],
	["invalid keys", { action: "keypress", ref: "@e1", keys: [1] }],
	["empty keys", { action: "keypress", ref: "@e1", keys: [] }],
	["blank key", { action: "keypress", ref: "@e1", keys: ["cmd", " "] }],
	["orphaned typing", { action: "typeText", text: "orphaned" }],
	["orphaned keypress", { action: "keypress", keys: ["return"] }],
	["missing text", { action: "setText", ref: "@e1" }],
	["numeric text", { action: "setText", ref: "@e1", text: 5 }],
	["short drag", { action: "drag", path: [{ x: 1, y: 1 }] }],
	["invalid drag point", { action: "drag", path: [{ x: 1, y: 1 }, { x: "bad", y: 2 }] }],
	["drag point with extra key", { action: "drag", path: [{ x: 1, y: 1 }, { x: 2, y: 2, z: 3 }] }],
	["drag pair of three", { action: "drag", path: [[1, 1], [2, 2, 2]] }],
	["unsupported field", { action: "wait", button: "left" }],
	["unknown field", { action: "click", ref: "@e1", extra: true }],
	["first bad field wins", { action: "click", extra: true, ref: 123 }],
	["missing target", { action: "click" }],
	["setText without target", { action: "setText", text: "x" }],
	["numeric action", { action: 5 }],
	["null action", { action: null }],
	["missing action", { ref: "@e1" }],
	["unknown action", { action: "hover", ref: "@e1" }],
]) validateCase(name, [action]);
for (const [name, actions] of [
	["click ref", [{ action: "click", ref: "@e1" }]],
	["click coordinates with options", [{ action: "click", x: 10, y: 10.5, button: "middle", clickCount: 3 }]],
	["scroll defaults", [{ action: "scroll", ref: "@e1" }]],
	["wait default", [{ action: "wait" }]],
	["wait zero", [{ action: "wait", ms: 0 }]],
	["drag mixed points", [{ action: "drag", path: [[1, 1], { x: 2, y: 2 }] }]],
	["empty setText", [{ action: "setText", ref: "@e1", text: "" }]],
	["typing after a coordinate click", [{ action: "click", x: 10, y: 10 }, { action: "typeText", text: "focused" }]],
	["every action kind", [
		{ action: "press", ref: "@e1", button: "right" },
		{ action: "doubleClick", x: 1, y: 2 },
		{ action: "typeText", text: "t" },
		{ action: "keypress", keys: ["cmd", "s"] },
		{ action: "setText", ref: "@e2", text: "v" },
		{ action: "scroll", x: 3, y: 4, scrollX: -10_000, scrollY: 2.5 },
		{ action: "drag", ref: "@e3", path: [{ y: 2, x: 1 }, [3, 4]] },
		{ action: "moveMouse", ref: "@e4" },
		{ action: "wait", ms: 60_000 },
	]],
	["no actions", []],
	["too many actions", Array.from({ length: 21 }, () => ({ action: "wait" }))],
	["twenty actions", Array.from({ length: 20 }, () => ({ action: "wait" }))],
	["array item", [[]]],
	["null item", [null]],
	["number item", [1]],
]) validateCase(name, actions);

const prepareOutline = inline("look-prepare", windowRoot([
	{ ref: "toolbar", role: "AXToolbar", title: "Toolbar", rect: { x: 0, y: 0, w: 800, h: 40 } },
	{ ref: "editor", role: "AXTextArea", value: "", canSetValue: true, isTextInput: true, rect: { x: 10, y: 50, w: 400, h: 300 } },
	{ ref: "save", role: "AXButton", title: "Save", actions: ["AXPress"], canPress: true, rect: { x: 700, y: 10, w: 60, h: 21 } },
	{ ref: "menuonly", role: "AXImage", description: "Logo", actions: ["AXShowMenu", "AXScrollToVisible"], rect: { x: 20, y: 400, w: 31, h: 31 } },
	{ ref: "custom", role: "AXGroup", title: "Custom", actions: ["AXCustom"], rect: { x: 100, y: 400, w: 10, h: 10 } },
	{ ref: "ocr", role: "AXStaticText", value: "Text", pictureOnly: true, rect: { x: 200, y: 500, w: 101, h: 20 } },
	{ ref: "far", role: "AXButton", title: "Far", actions: ["AXPress"], canPress: true, rect: { x: 900, y: 10, w: 20, h: 20 } },
	{ role: "AXGroup", title: "No wire ref", children: [{ ref: "nested-text", role: "AXStaticText", value: "inside" }], rect: { x: 300, y: 300, w: 20, h: 20 } },
]));
const IMAGE = { width: 800, height: 600 };
/** `image: null` is a state observed without an image. */
function prepareCase(name, action, { currentFocus = false, headless = false, image: requestedImage = IMAGE } = {}) {
	const image = requestedImage ?? undefined;
	const outline = loadOutline(prepareOutline);
	const look = { image };
	const output = catching(() => ({ prepared: canonicalJson(prepareAction(action, { currentFocus }, {
		headless,
		image,
		node: (ref) => nodeByRef(outline, ref),
		center: outlineNodeCenter,
		validatePoint: (x, y, label) => ensurePointIsInLookImage(x, y, look, label),
	})) }));
	add("actions", name, "prepare", { outline: prepareOutline, action, currentFocus, headless, image }, output);
}
prepareCase("click an editor establishes focus", { action: "click", ref: "@e3" });
prepareCase("headless click does not establish focus", { action: "click", ref: "@e3" }, { headless: true });
prepareCase("click by wire ref", { action: "click", ref: "save" });
prepareCase("press a button", { action: "press", ref: "@e4", button: "right", clickCount: 2 });
prepareCase("click a node without press falls back to its center", { action: "click", ref: "@e2" });
prepareCase("click a node with only incidental actions", { action: "click", ref: "@e5" });
prepareCase("click a node with a custom action", { action: "click", ref: "@e6" });
prepareCase("click text read from the screen", { action: "click", ref: "@e7" });
prepareCase("click a node without a wire ref", { action: "click", ref: "@e9" });
prepareCase("a pressable ref outside the image keeps its ref", { action: "click", ref: "@e8" });
prepareCase("click coordinates", { action: "click", x: 799.5, y: 0 });
prepareCase("click coordinates outside the image", { action: "click", x: 800, y: 10.4 });
prepareCase("coordinates without an image", { action: "click", x: 1, y: 1 }, { image: null });
prepareCase("double click", { action: "doubleClick", ref: "@e4" });
prepareCase("setText keeps the element", { action: "setText", ref: "@e3", text: "hello" });
prepareCase("typeText into the current focus", { action: "typeText", text: "hello" }, { currentFocus: true });
prepareCase("keypress into the current focus of an odd image", { action: "keypress", keys: ["return"] }, { currentFocus: true, image: { width: 801, height: 599 } });
prepareCase("typeText without an image", { action: "typeText", text: "hello" }, { currentFocus: true, image: null });
prepareCase("headless typeText without a target", { action: "typeText", text: "hello" }, { currentFocus: true, headless: true });
prepareCase("typeText into a ref ignores focus", { action: "typeText", ref: "@e3", text: "x" }, { currentFocus: true });
prepareCase("keypress on a ref", { action: "keypress", ref: "@e3", keys: ["cmd", "a"] });
prepareCase("scroll defaults", { action: "scroll", ref: "@e3" });
prepareCase("scroll rounds to whole steps", { action: "scroll", x: 5, y: 5, scrollX: -2.4, scrollY: 2.6 });
prepareCase("wait default", { action: "wait" });
prepareCase("wait rounds", { action: "wait", ms: 10.5 });
prepareCase("drag path", { action: "drag", path: [[1, 2], { x: 3.5, y: 4 }] });
prepareCase("drag from a ref", { action: "drag", ref: "@e3", path: [[1, 2], [3, 4]] });
prepareCase("drag point outside the image", { action: "drag", path: [[1, 2], [3, 700]] });
prepareCase("moveMouse to a ref", { action: "moveMouse", ref: "@e4" });

for (const [fn, args, result] of [
	["canRetryInForeground", ["didnt", false], canRetryInForeground("didnt", false)],
	["canRetryInForeground", ["unknown", false], canRetryInForeground("unknown", false)],
	["canRetryInForeground", ["worked", false], canRetryInForeground("worked", false)],
	["canRetryInForeground", ["didnt", true], canRetryInForeground("didnt", true)],
	...["worked", "didnt", "unknown"].flatMap((current) => ["verified", "preexisting", "failed"].map((check) => ["outcomeAfterCheck", [current, check], outcomeAfterCheck(current, check)])),
]) add("actions", `${fn} ${args.join(" ")}`, "outcome", { fn, args }, { result: JSON.stringify(result) });
for (const [name, current, actions, values] of [
	["setText value observed", "didnt", [{ action: "setText", ref: "@e1", text: "saved" }], { "@e1": "saved" }],
	["setText value differs", "didnt", [{ action: "setText", ref: "@e1", text: "saved" }], { "@e1": "old" }],
	["waits only", "unknown", [{ action: "wait" }], {}],
	["setText and wait", "unknown", [{ action: "setText", ref: "@e1", text: "" }, { action: "wait" }], { "@e1": "" }],
	["setText then click", "unknown", [{ action: "setText", ref: "@e1", text: "a" }, { action: "click", ref: "@e1" }], { "@e1": "a" }],
	["missing element", "unknown", [{ action: "setText", ref: "@e9", text: "" }], {}],
]) add("actions", `outcomeAfterObservedValues ${name}`, "observedValues", { current, actions, values }, { result: JSON.stringify(outcomeAfterObservedValues(current, actions, (ref) => values[ref])) });

// errors.json: the stable error surface.
for (const [name, code, message, recovery] of [
	...["invalid_arguments", "stale_state", "permission_missing", "app_not_found", "window_stale", "element_not_found", "action_timeout", "action_failed", "broker_unavailable", "helper_unavailable", "unsupported_platform", "state_too_large", "internal_error"].map((code) => [code, code, `A ${code} failure.`]),
	["whitespace collapses", "stale_state", "  first line\n\tsecond\u00a0line  "],
	["empty message", "internal_error", "   "],
	["custom recovery", "helper_unavailable", "Daemon lost.", "The action may already have taken effect."],
]) {
	add("errors", name, "error", { code, message, recovery }, formatted(new BcuError(code, message, recovery)));
}

// ---- the CLI against a recording fake Broker ----

const temporaryRoot = await makeTemporaryRoot("swift-golden");
await buildBundle();

async function withServer(socketPath, handle, work) {
	const server = net.createServer((socket) => {
		socket.setEncoding("utf8");
		let buffer = "";
		socket.on("error", () => undefined);
		socket.on("data", (chunk) => {
			buffer += chunk;
			for (let newline = buffer.indexOf("\n"); newline >= 0; newline = buffer.indexOf("\n")) {
				const request = JSON.parse(buffer.slice(0, newline));
				buffer = buffer.slice(newline + 1);
				socket.write(`${JSON.stringify({ id: request.id, ...handle(request) })}\n`);
			}
		});
	});
	server.listen(socketPath);
	await once(server, "listening");
	try {
		return await work();
	} finally {
		await new Promise((resolve) => server.close(resolve));
	}
}

/** stdin parse failures carry V8's own wording after this prefix; it is not part of the contract. */
const STDIN_PREFIX = "act-ui stdin must be a JSON action array: ";
function withoutParserDetail(stderr) {
	return stderr.replace(new RegExp(`(${STDIN_PREFIX}).*`), "$1<parser detail>");
}

/** A parse that reached the Broker is judged by the request it sent; everything else by its streams. */
function cliOutput(result, request, rendered = true) {
	return {
		...(request ? { request: canonicalJson(request) } : {}),
		...(rendered ? { stdout: result.stdout, stderr: withoutParserDetail(result.stderr), exitCode: result.code } : {}),
	};
}

const fakeBroker = path.join(temporaryRoot, "fake-broker.sock");
const fakeEnv = { ...process.env, BCU_BROKER_SOCKET_PATH: fakeBroker, BCU_BROKER_ENTRY_PATH: path.join(temporaryRoot, "no-broker.mjs") };
let cannedResult = {};
let recorded;
await withServer(fakeBroker, (request) => {
	if (request.cmd === "hello") return { ok: true, result: { brokerVersion: 1, helperProtocolVersion: null, pid: 1 } };
	recorded = { command: request.cmd, params: request.args };
	return { ok: true, result: cannedResult };
}, async () => {
	async function cliCase(name, argv, { stdin, result } = {}) {
		recorded = undefined;
		cannedResult = result ?? {};
		const run = await runCli(argv, { env: fakeEnv, input: stdin ?? "" });
		add("cli", name, "cli", { argv, stdin, result }, cliOutput(run, recorded && { ...recorded, json: argv.includes("--json") }, !recorded || result !== undefined));
	}

	for (const argv of [[], ["--help"], ["-h"], ["--json"], ["bogus", "--help"], ["search-ui", "--state", "s", "--text", "-h"]]) {
		await cliCase(`help ${argv.join(" ") || "(none)"}`, argv);
	}
	for (const command of ["find-roots", "observe-ui", "search-ui", "expand-ui", "inspect-ui", "act-ui", "read-text", "wait-for", "status", "doctor", "setup", "stop"]) {
		await cliCase(`help ${command}`, [command, "--help"]);
	}
	for (const [name, argv, stdin] of [
		["find-roots bare", ["find-roots"]],
		["find-roots every option", ["find-roots", "--query", "  Text  ", "--app", "TextEdit", "--bundle-id", "com.apple.TextEdit", "--pid", "42", "--kind", "menubar"]],
		["find-roots options in another order", ["find-roots", "--pid", "7", "--query", "x", "--json"]],
		["find-roots hex pid", ["find-roots", "--pid", "0x10"]],
		["find-roots empty pid is zero", ["find-roots", "--pid", ""]],
		["find-roots padded pid", ["find-roots", "--pid", " 7 "]],
		["find-roots exponent pid", ["find-roots", "--pid", "1e3"]],
		["find-roots fractional pid", ["find-roots", "--pid", ".5"]],
		["find-roots signed pid", ["find-roots", "--pid", "-3"]],
		["find-roots bad pid", ["find-roots", "--pid", "abc"]],
		["find-roots pid out of range", ["find-roots", "--pid", "99999999999999999999"]],
		["find-roots bad kind", ["find-roots", "--kind", "bogus"]],
		["find-roots duplicate option", ["find-roots", "--app", "A", "--app", "B"]],
		["find-roots missing value", ["find-roots", "--app"]],
		["find-roots value that is an option", ["find-roots", "--app", "--pid", "3"]],
		["find-roots positional", ["find-roots", "extra"]],
		["find-roots unknown option", ["find-roots", "--nope"]],
		["find-roots single dash value", ["find-roots", "--app", "-x"]],
		["observe-ui every option", ["observe-ui", "--app", "TextEdit", "--window-title", "未命名", "--root", "@r3", "--mode", "fused", "--image", "always", "--read-text", "never"]],
		["observe-ui bad mode", ["observe-ui", "--mode", "x"]],
		["search-ui every option", ["search-ui", "--state", "abc", "--text", "Save", "--role", "button", "--action", "press", "--limit", "5"]],
		["search-ui keeps raw values", ["search-ui", "--state", " abc ", "--text", "  "]],
		["search-ui without a state", ["search-ui", "--text", "x"]],
		["search-ui blank state", ["search-ui", "--state", "  "]],
		["expand-ui every option", ["expand-ui", "--state", " s ", "--ref", " @e3 ", "--depth", "2"]],
		["expand-ui without a ref", ["expand-ui", "--state", "s"]],
		["expand-ui checks the ref after the positional", ["expand-ui", "x"]],
		["inspect-ui", ["inspect-ui", "--state", "s", "--ref", "@e1"]],
		["inspect-ui without a state", ["inspect-ui", "--ref", "@e1"]],
		["read-text every option", ["read-text", "--state", "s", "--ref", "@e2", "--offset", "10", "--limit", "20"]],
		["read-text without a ref", ["read-text", "--state", "s"]],
		["wait-for every option", ["wait-for", "--state", "s", "--text", "Saved", "--scope", "@e2", "--gone", "--timeout", "2000"]],
		["wait-for role", ["wait-for", "--state", "s", "--role", "button"]],
		["wait-for without a condition", ["wait-for", "--state", "s"]],
		["wait-for blank role", ["wait-for", "--state", "s", "--role", "  "]],
		["wait-for without a state", ["wait-for", "--text", "x"]],
		["act-ui one action", ["act-ui", "--state", "s", "-"], "[{\"action\":\"click\",\"ref\":\"@e1\"}]\n"],
		["act-ui every option", ["act-ui", "--state", "s", "--expect-text", " Done ", "--expect-role", "button", "--expect-value", "1", "--scope", "@e2", "--timeout", "500", "--expect-gone", "--headless", "--image", "always", "-"], JSON.stringify([
			{ action: "click", x: 10.0, y: 20.25, button: "right", clickCount: 2 },
			{ action: "typeText", text: "héllo\n" },
			{ action: "drag", path: [[1, 2], { x: 3, y: 4 }] },
		])],
		["act-ui expect value only", ["act-ui", "--state", "s", "--expect-value", "x", "-"], "[{\"action\":\"wait\"}]"],
		["act-ui blank expectation is dropped", ["act-ui", "--state", "s", "--expect-text", "  ", "-"], "[{\"action\":\"wait\"}]"],
		["act-ui without the dash", ["act-ui", "--state", "s"]],
		["act-ui with two dashes", ["act-ui", "--state", "s", "-", "-"]],
		["act-ui dash checked before state", ["act-ui"]],
		["act-ui without a state", ["act-ui", "-"], "[]"],
		["act-ui scope without an expectation", ["act-ui", "--state", "s", "--scope", "@e1", "-"], "[]"],
		["act-ui timeout without an expectation", ["act-ui", "--state", "s", "--timeout", "10", "-"], "[]"],
		["act-ui gone without an expectation", ["act-ui", "--state", "s", "--expect-gone", "-"], "[]"],
		["act-ui stdin is not JSON", ["act-ui", "--state", "s", "-"], "not-json\n"],
		["act-ui stdin is empty", ["act-ui", "--state", "s", "-"], ""],
		["act-ui stdin is not an array", ["act-ui", "--state", "s", "-"], "{\"action\":\"click\"}"],
		["act-ui item without an action", ["act-ui", "--state", "s", "-"], "[{\"act\":\"click\"}]"],
		["act-ui item with an unknown action", ["act-ui", "--state", "s", "-"], "[{\"action\":\"hover\"}]"],
		["act-ui null item", ["act-ui", "--state", "s", "-"], "[null]"],
		["unknown command", ["bogus"]],
		["plain command with an option", ["status", "extra"]],
		["plain command with json and an option", ["stop", "--json", "--x"]],
	]) await cliCase(name, argv, { stdin });

	const textedit = loadOutline(fresh("textedit-outline.json"));
	const texteditView = project(textedit);
	const ROOT_SUMMARY = { ref: "@r1", app: "TextEdit", pid: 101, title: "未命名2", windowId: 1010, frame: { x: 0, y: 25.5, w: 586, h: 488 }, scale: 2 };
	const renderCases = [
		["find-roots", ["find-roots"], { roots: [
			{ ref: "@r1", app: "TextEdit", bundleId: "com.apple.TextEdit", pid: 101, title: "未命名2", windowId: 1010, kind: "window", frame: { x: 0, y: 25, w: 586, h: 488 }, focused: true, main: true, onscreen: true, minimized: false, modal: false },
			{ ref: "@r2", app: "TextEdit", pid: 101, title: "TextEdit \"menu\"", kind: "menubar", frame: { x: 0, y: 0, w: 1512, h: 33 }, focused: false, main: false, onscreen: true, minimized: false, modal: false },
			{ ref: "@r3", app: "Finder", bundleId: "com.apple.finder", pid: 102, title: "", windowId: 7, kind: "sheet", frame: { x: -10, y: 0, w: 1, h: 1 }, focused: false, main: false, onscreen: false, minimized: true, modal: true },
			{ ref: "@r4", app: "Idle", pid: 103, title: "idle", windowId: 8, kind: "window", frame: { x: 0, y: 0, w: 1, h: 1 }, focused: false, main: false, onscreen: false, minimized: false, modal: false },
		] }],
		["find-roots empty", ["find-roots"], { roots: [] }],
		["observe-ui", ["observe-ui", "--app", "TextEdit"], { stateId: "1a2b3c4d", root: ROOT_SUMMARY, nodes: texteditView.nodes, shown: texteditView.shown, total: texteditView.total }],
		["observe-ui with an image", ["observe-ui", "--app", "TextEdit", "--image", "always"], { stateId: "1a2b3c4d", root: { ...ROOT_SUMMARY, ref: undefined, windowId: undefined }, nodes: texteditView.nodes.slice(0, 3), shown: 3, total: 47, image: { path: "/tmp/shots/1a2b3c4d.jpg", mime: "image/jpeg", width: 1172, height: 976 } }],
		["search-ui", ["search-ui", "--state", "s", "--text", "x"], { stateId: "s", matches: [{ ...texteditView.nodes[1], depth: 0, path: [] }, { ...texteditView.nodes[2], depth: 0, path: ["@e1", "@e2"] }], total: 5 }],
		["expand-ui", ["expand-ui", "--state", "s", "--ref", "@e1"], { stateId: "s", ref: "@e1", nodes: texteditView.nodes.slice(0, 4) }],
		["expand-ui nothing to show", ["expand-ui", "--state", "s", "--ref", "@e9"], { stateId: "s", ref: "@e9", nodes: [] }],
		["inspect-ui", ["inspect-ui", "--state", "s", "--ref", "@e2"], { stateId: "s", node: { ...serializeOutline(textedit).root.children[0], children: [] }, owners: { press: "@e5", typeText: "@e6" } }],
		["read-text", ["read-text", "--state", "s", "--ref", "@e2"], { stateId: "s", ref: "@e2", offset: 10, limit: 20, total: 100, text: "line one\nline two" }],
		["read-text empty", ["read-text", "--state", "s", "--ref", "@e2"], { stateId: "s", ref: "@e2", offset: 0, limit: 4000, total: 0, text: "" }],
		["wait-for with changes", ["wait-for", "--state", "s", "--text", "x"], { stateId: "t", found: true, ...views.typed }],
		["wait-for gone without changes", ["wait-for", "--state", "s", "--text", "x", "--gone"], { stateId: "t", found: true, gone: true, ...views.unchanged }],
		["wait-for full view", ["wait-for", "--state", "s", "--text", "x"], { stateId: "t", found: true, ...views.full }],
		["wait-for offscreen only", ["wait-for", "--state", "s", "--text", "x"], { stateId: "t", found: true, changes: [], offscreen: { added: 0, removed: 3 } }],
		["act-ui verified", ["act-ui", "--state", "s", "-"], { stateId: "t", baseStateId: "s", outcome: "worked", verification: { status: "verified", evidence: { source: "ax", field: "value", from: "0", to: "1" }, text: "Done", role: undefined, value: undefined, scope: "@e2", gone: undefined, timeoutMs: 10000, preexisting: true }, delivery: "ax", roots: [{ ref: "@r12", kind: "menu", app: "TextEdit", title: "文件" }], ...views.typed, image: { path: "/tmp/shots/t.jpg", mime: "image/jpeg", width: 10, height: 20 } }],
		["act-ui unverified", ["act-ui", "--state", "s", "-"], { stateId: "t", baseStateId: "s", outcome: "unknown", verification: { status: "none" }, delivery: "pid", ...views.unchanged }],
		["act-ui screen evidence with offscreen noise", ["act-ui", "--state", "s", "-"], { stateId: "t", baseStateId: "s", outcome: "worked", verification: { status: "none", evidence: { source: "screen", field: "changed" } }, delivery: "hid", ...views.noisy }],
		["act-ui focus evidence", ["act-ui", "--state", "s", "-"], { stateId: "t", baseStateId: "s", outcome: "worked", verification: { status: "none", evidence: { source: "focus" } }, delivery: "pid", ...views.menus }],
		["act-ui field evidence", ["act-ui", "--state", "s", "-"], { stateId: "t", baseStateId: "s", outcome: "worked", verification: { status: "verified", evidence: { source: "ax", field: "selected" }, text: "x", timeoutMs: 100 }, delivery: "ax", ...views.full }],
		["act-ui root closed", ["act-ui", "--state", "s", "-"], { stateId: "t", baseStateId: "s", outcome: "worked", verification: { status: "none", evidence: { source: "root", field: "closed" } }, delivery: "ax", roots: undefined, closed: { root: { ref: "@r5", kind: "sheet", app: "TextEdit", title: "警告" }, skipped: 1 }, next: { ref: "@r1", kind: "window", app: "TextEdit", title: "未命名2" }, ...views.full, image: undefined }],
		["act-ui last root closed", ["act-ui", "--state", "s", "-"], { baseStateId: "s", outcome: "worked", verification: { status: "none", evidence: { source: "root", field: "closed" } }, delivery: "ax", roots: [{ ref: "@r9", kind: "dialog", app: "TextEdit", title: "" }], closed: { root: { ref: "@r5", kind: "sheet", app: "TextEdit", title: "警告" }, skipped: 2 } }],
	];
	for (const [name, argv, result] of renderCases) {
		const stdin = argv[0] === "act-ui" ? "[{\"action\":\"wait\"}]" : undefined;
		await cliCase(`render ${name}`, argv, { stdin, result });
		await cliCase(`render ${name} --json`, [...argv, "--json"], { stdin, result });
	}
	// The closed-root verification is built as {status, evidence, gone, scope}, the only result
	// whose key order differs from its declared shape; the Swift type encodes one order.
	const closedExpectation = { baseStateId: "s", outcome: "worked", verification: { status: "verified", evidence: { source: "root", field: "closed" }, gone: true, scope: "@e4" }, delivery: "ax", closed: { root: { ref: "@r5", kind: "sheet", app: "TextEdit", title: "警告" } } };
	await cliCase("render act-ui closed root satisfies expect-gone", ["act-ui", "--state", "s", "-"], { stdin: "[{\"action\":\"wait\"}]", result: closedExpectation });
	await cliCase("render act-ui closed root satisfies expect-gone --json", ["act-ui", "--state", "s", "--json", "-"], { stdin: "[{\"action\":\"wait\"}]", result: closedExpectation });
	files.cli.at(-1).compare = "canonical-json";
});

// ---- search, expand, inspect and action delivery against the real Broker ----

const APPS = [
	{ pid: 101, appName: "TextEdit", bundleId: "com.apple.TextEdit", fixture: "textedit-outline.json", title: "未命名2" },
	{ pid: 102, appName: "Finder", bundleId: "com.apple.finder", fixture: "finder-outline.json", title: "MacBook Pro" },
	{ pid: 103, appName: "Chrome", bundleId: "com.google.Chrome", fixture: "chrome-outline.json", title: "bcu web background" },
	{ pid: 104, appName: "Editor", bundleId: "com.example.editor", fixture: "editor-outline.json", title: "bcu editor fixture" },
];
const LOOK_IMAGE = { width: 1172, height: 976 };
const appByWindow = (windowId) => APPS.find((app) => app.pid * 10 === windowId);
const rootOf = (app) => ({
	kind: "window", windowRef: `w${app.pid}`, rootRef: `w${app.pid}`, windowId: app.pid * 10, pid: app.pid, appName: app.appName, bundleId: app.bundleId,
	title: app.title, role: "AXWindow", subrole: "AXStandardWindow", framePoints: { x: 0, y: 25.5, w: 586, h: 488 }, scaleFactor: 2, zOrder: 1,
	isMinimized: false, isOnscreen: true, isMain: true, isFocused: true, isModal: false, metadata: { pairing: { confidence: "exact", score: 110 } },
});
const actRequests = [];
function helperResult(request) {
	switch (request.cmd) {
		case "diagnostics": return { protocolVersion: HELPER_PROTOCOL_VERSION, architectureVersion: HELPER_ARCHITECTURE_VERSION, invariants: [...REQUIRED_HELPER_INVARIANTS], pid: process.pid };
		case "checkPermissions": return { accessibility: true, screenRecordingCapturable: true, screenRecordingPreflight: true, source: { attribution: "helper-app", pid: process.pid } };
		case "listApps": return { apps: APPS.map(({ pid, appName, bundleId }) => ({ pid, appName, bundleId, isFrontmost: pid === 101 })) };
		case "listRoots": return { roots: APPS.filter((app) => app.pid === request.pid).map(rootOf) };
		case "getFrontmost": return { pid: 101, appName: "TextEdit", bundleId: "com.apple.TextEdit", windowId: 1010, windowTitle: "未命名2" };
		case "look": {
			const app = appByWindow(request.windowId);
			return {
				lookId: fixtures[app.fixture].lookId,
				capturedAt: 0,
				window: { windowId: request.windowId, rootRef: `w${app.pid}`, kind: "window", framePoints: { x: 0, y: 25.5, w: 586, h: 488 }, scaleFactor: 2, isModal: false, role: "AXWindow", subrole: "AXStandardWindow" },
				image: { jpegBase64: "", mimeType: "image/jpeg", ...LOOK_IMAGE },
				outline: toWireNode(fixtures[app.fixture].root),
				timings: {},
				readText: { requested: "auto", executed: true },
			};
		}
		case "act": actRequests.push(request); return { outcome: "worked", performed: { delivery: "ax" } };
		default: return {};
	}
}

const helperSocket = path.join(temporaryRoot, "helper.sock");
const brokerSocket = path.join(temporaryRoot, "broker.sock");
const env = { ...brokerEnvironment(brokerSocket, 60_000), BCU_SOCKET_PATH: helperSocket, BCU_HEADLESS: "0", BCU_CURSOR_OVERLAY: "0" };
await withServer(helperSocket, (request) => ({ ok: true, result: helperResult(request) }), async () => {
	const broker = spawnBroker(env);
	try {
		await withTimeout(once(broker.ready, "data"), "the golden broker to signal readiness", 20_000);
		for (const app of APPS) {
			const observe = ["observe-ui", "--app", app.appName];
			const observed = JSON.parse((await runCli([...observe, "--json"], { env })).stdout);
			const base = { outline: fresh(app.fixture), stateId: observed.stateId, root: observed.root };
			const query = async (name, argv) => {
				for (const variant of [argv, [...argv, "--json"]]) {
					add("queries", `${app.appName} ${name}${variant === argv ? "" : " --json"}`, "query", { ...base, argv: variant }, cliOutput(await runCli(variant, { env })));
				}
			};
			const state = ["--state", observed.stateId];
			for (const variant of [observe, [...observe, "--json"]]) {
				const run = await runCli(variant, { env });
				const stateId = /state ([0-9a-f]{8})/.exec(run.stdout)?.[1] ?? JSON.parse(run.stdout).stateId;
				add("queries", `${app.appName} observe${variant === observe ? "" : " --json"}`, "query", { ...base, stateId, argv: variant }, cliOutput(run));
			}
			await query("search textarea", ["search-ui", ...state, "--role", "textarea"]);
			await query("search AX role name", ["search-ui", ...state, "--role", "AXButton", "--limit", "3"]);
			await query("search setText", ["search-ui", ...state, "--action", "setText"]);
			await query("search scroll", ["search-ui", ...state, "--action", "SCROLL", "--limit", "50"]);
			await query("search menu", ["search-ui", ...state, "--action", "menu", "--limit", "50"]);
			await query("search text", ["search-ui", ...state, "--text", { Finder: "下载", Editor: "Fifth line" }[app.appName] ?? "  NEW  "]);
			await query("search limit clamps", ["search-ui", ...state, "--text", "a", "--limit", "0"]);
			await query("search limit above 50", ["search-ui", ...state, "--limit", "500"]);
			await query("search no match", ["search-ui", ...state, "--text", "__nothing__"]);
			await query("search unknown capability", ["search-ui", ...state, "--action", "hover"]);
			await query("expand root", ["expand-ui", ...state, "--ref", "@e1"]);
			await query("expand depth 1", ["expand-ui", ...state, "--ref", "@e2", "--depth", "1"]);
			await query("expand depth clamps", ["expand-ui", ...state, "--ref", "@e3", "--depth", "99"]);
			await query("expand by wire ref", ["expand-ui", ...state, "--ref", fixtures[app.fixture].root.children[0].wireRef]);
			await query("expand unknown ref", ["expand-ui", ...state, "--ref", "@e999"]);
			await query("inspect root", ["inspect-ui", ...state, "--ref", "@e1"]);
			await query("inspect unknown ref", ["inspect-ui", ...state, "--ref", "@e999"]);
			const projected = project(loadOutline(fresh(app.fixture)), UNFOLDED).nodes;
			for (const node of projected.filter((candidate) => candidate.owners).slice(0, 3)) await query(`inspect owner ${node.ref}`, ["inspect-ui", ...state, "--ref", node.ref]);
			for (const node of projected.filter((candidate) => candidate.caps.includes("setText")).slice(0, 1)) await query(`inspect editable ${node.ref}`, ["inspect-ui", ...state, "--ref", node.ref]);

			// Where each action lands: the element that owns the capability, or a point.
			// Each delivery starts from its own observation: a second write from one state is stale.
			const deliver = async (name, action) => {
				const freshState = JSON.parse((await runCli([...observe, "--json"], { env })).stdout).stateId;
				actRequests.length = 0;
				const run = await runCli(["act-ui", "--state", freshState, "--json", "-"], { env, input: JSON.stringify([action]) });
				const request = actRequests[0];
				const output = request
					? { request: canonicalJson({ action: request.action, target: request.target, params: { ...request.params, delivery: undefined } }) }
					: { stderr: run.stderr, exitCode: run.code };
				add("actions", `${app.appName} deliver ${name}`, "deliver", { outline: fresh(app.fixture), image: LOOK_IMAGE, action }, output);
			};
			for (const node of projected.filter((candidate) => candidate.owners).slice(0, 3)) {
				await deliver(`press ${node.ref} through its owner`, { action: "press", ref: node.ref });
				await deliver(`setText ${node.ref}`, { action: "setText", ref: node.ref, text: "x" });
			}
			for (const node of projected.filter((candidate) => candidate.caps.includes("scroll")).slice(0, 2)) await deliver(`scroll ${node.ref}`, { action: "scroll", ref: node.ref, scrollY: 3 });
			for (const node of projected.filter((candidate) => candidate.caps.includes("press")).slice(0, 2)) await deliver(`click ${node.ref}`, { action: "click", ref: node.ref });
			await deliver("click unknown ref", { action: "click", ref: "@e999" });
			await deliver("click a point", { action: "click", x: 100, y: 200 });
		}
	} finally {
		await runCli(["stop"], { env }).catch(() => undefined);
		if (broker.process.exitCode === null) broker.process.kill("SIGTERM");
	}
});
fs.rmSync(temporaryRoot, { recursive: true, force: true });

// Declared differences from the TS CLI: numeric options are integers written in decimal
// digits. What Number() also accepted — hex and binary prefixes, exponents, fractions,
// signs, padding, the empty string — and values beyond the integer range are rejected.
const STRICT_INTEGER_CASES = [
	"find-roots hex pid",
	"find-roots empty pid is zero",
	"find-roots padded pid",
	"find-roots exponent pid",
	"find-roots fractional pid",
	"find-roots signed pid",
	"find-roots bad pid",
	"find-roots pid out of range",
];
for (const golden of files.cli.filter((candidate) => STRICT_INTEGER_CASES.includes(candidate.name))) {
	golden.output = { stdout: "", ...formatted(new BcuError("invalid_arguments", "Option '--pid' requires a non-negative integer.")) };
}

fs.mkdirSync(GOLDEN, { recursive: true });
for (const [name, cases] of Object.entries(files)) {
	fs.writeFileSync(path.join(GOLDEN, `${name}.json`), `${JSON.stringify({ cases }, null, "\t")}\n`);
	console.log(`${name}.json: ${cases.length} cases`);
}
