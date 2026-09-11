#!/usr/bin/env node
// Pure runtime units the public commands are built on: bounded saved state, per-resource
// scheduling and stale epochs, action preparation, successor diffs, root selection, and
// the config and permission decisions no command can observe end to end.
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { canRetryInForeground, outcomeAfterCheck, outcomeAfterObservedValues, prepareAction } from "../src/actions.ts";
import { loadComputerUseConfig } from "../src/config.ts";
import { ensurePermissions } from "../src/macos/permissions.ts";
import { shouldPreferForegroundModalWindow } from "../src/root-selection.ts";
import { graftScopedOutline, nodeByRef, parseLookResponse } from "../src/outline.ts";
import { project } from "../src/projection.ts";
import { ResourceScheduler, StateStore, StaleResourceStateError } from "../src/runtime.ts";
import { SavedStates } from "../src/state.ts";
import { changesBetween, stabilizeRefs } from "../src/view.ts";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const states = new StateStore(2);
const first = states.create("pid:1", 0, { label: "first" });
states.create("pid:2", 0, { label: "second" });
states.create("pid:3", 0, { label: "third" });
assert.equal(states.get(first.stateId), undefined, "bounded state store did not evict oldest state");

let storeTime = 1_000;
const byteAndTtlBounded = new StateStore({
	maxEntries: 10,
	maxBytes: 1_500,
	maxRecordBytes: 1_400,
	ttlMs: 100,
	now: () => storeTime,
});
const byteOldest = byteAndTtlBounded.create("pid:bytes", 0, { value: "a".repeat(900) });
byteAndTtlBounded.create("pid:bytes", 0, { value: "b".repeat(900) });
assert.equal(byteAndTtlBounded.get(byteOldest.stateId), undefined, "byte capacity did not evict the oldest state");
assert.throws(
	() => byteAndTtlBounded.create("pid:bytes", 0, { value: "x".repeat(2_000) }),
	(error) => error?.code === "state_too_large",
	"single-state capacity did not reject an oversized state",
);
const expiring = byteAndTtlBounded.create("pid:ttl", 0, { value: "short" });
storeTime += 101;
byteAndTtlBounded.create("pid:ttl", 0, { value: "new" });
assert.equal(byteAndTtlBounded.get(expiring.stateId), undefined, "TTL cleanup did not run on write");

const rawLook = (lookId, children, image) => parseLookResponse({
	lookId,
	capturedAt: Date.now() / 1000,
	window: { windowId: 1, framePoints: { x: 0, y: 0, w: 800, h: 600 }, scaleFactor: 1, isModal: false, role: "AXWindow", subrole: "AXStandardWindow" },
	image,
	outline: { ref: "window", role: "AXWindow", children },
	timings: {},
});

const baseLook = rawLook("look-1", [
	{ ref: "toolbar", role: "AXToolbar", title: "Toolbar" },
	{ ref: "editor", role: "AXTextArea", value: "", canSetValue: true, isTextInput: true },
]);
const nextLook = rawLook("look-2", [
	{ ref: "inserted", role: "AXStaticText", value: "Status" },
	{ ref: "toolbar", role: "AXToolbar", title: "Toolbar" },
	{ ref: "editor", role: "AXTextArea", value: "hello", canSetValue: true, isTextInput: true },
]);
const imageBytes = Buffer.from("state-store-must-not-retain-this-image").toString("base64");
const imageLook = rawLook("look-image", [{ ref: "button", role: "AXButton", title: "Save" }], {
	jpegBase64: imageBytes,
	mimeType: "image/jpeg",
	width: 800,
	height: 600,
});
const savedStates = new SavedStates();
savedStates.saveDesktop({
	currentTarget: { appName: "Fixture", pid: 1, windowTitle: "Fixture", windowId: 1 },
	currentCapture: { stateId: "state-image", timestamp: Date.now() },
	currentLook: imageLook,
	currentOutline: imageLook.parsedOutline,
}, "desktop-pid:1", 0);
const savedImageState = savedStates.get("state-image");
assert(savedImageState, "desktop observation was not saved");
assert(!JSON.stringify(savedImageState).includes(imageBytes), "StateStore retained screenshot base64 bytes");
const hydratedImage = savedStates.hydrate(savedImageState).currentLook?.image;
assert.deepEqual(hydratedImage, { mimeType: "image/jpeg", width: 800, height: 600 }, "stored state did not retain coordinate metadata");
stabilizeRefs(baseLook.parsedOutline, nextLook.parsedOutline);
assert.equal(nextLook.parsedOutline.wireRefToRef.get("editor"), baseLook.parsedOutline.wireRefToRef.get("editor"), "successor state did not preserve a confidently matched ref");
const projected = (outline) => project(outline, { maxDepth: Number.MAX_SAFE_INTEGER, maxNodes: Number.MAX_SAFE_INTEGER }).nodes;
const successorDiff = changesBetween(projected(baseLook.parsedOutline), projected(nextLook.parsedOutline));
assert.equal(successorDiff.useFullView, false, "small successor change unexpectedly required a full view");
assert(successorDiff.changes.some((change) => change.type === "updated" && change.ref === baseLook.parsedOutline.wireRefToRef.get("editor") && change.fields.value === "hello"), "successor diff omitted the editor value change");
assert(successorDiff.changes.some((change) => change.type === "added" && change.ref === nextLook.parsedOutline.wireRefToRef.get("inserted")), "successor diff omitted the added node");

const regeneratedLook = rawLook("look-3", [
	{ ref: "toolbar-new", role: "AXToolbar", title: "Toolbar" },
	{ ref: "editor-new", role: "AXTextArea", value: "updated", canSetValue: true, isTextInput: true },
]);
stabilizeRefs(baseLook.parsedOutline, regeneratedLook.parsedOutline);
const regeneratedEditor = regeneratedLook.parsedOutline.nodes.find((node) => node.wireRef === "editor-new");
assert.equal(regeneratedEditor?.ref, baseLook.parsedOutline.wireRefToRef.get("editor"), "structurally stable nodes did not retain refs when native refs regenerated");
assert.equal(changesBetween(projected(baseLook.parsedOutline), projected(regeneratedLook.parsedOutline)).useFullView, false, "regenerated native refs forced an unnecessary full view");

// Expanding a subtree the helper cut short must not renumber the state around it.
const graftBase = rawLook("look-graft", [
	{ ref: "toolbar", role: "AXToolbar", title: "Toolbar" },
	{ ref: "list", role: "AXList", title: "Files", truncated: true },
]);
const scopedLook = rawLook("look-graft-scope", []);
scopedLook.parsedOutline = parseLookResponse({
	lookId: "look-graft-scope",
	capturedAt: Date.now() / 1000,
	window: { windowId: 1, framePoints: { x: 0, y: 0, w: 800, h: 600 }, scaleFactor: 1, isModal: false, role: "AXWindow", subrole: "AXStandardWindow" },
	outline: { ref: "list", role: "AXList", title: "Files", children: [{ ref: "row-1", role: "AXRow", title: "one" }, { ref: "row-2", role: "AXRow", title: "two" }] },
	timings: {},
}).parsedOutline;
const graftTargetRef = graftBase.parsedOutline.wireRefToRef.get("list");
const graftBefore = new Map(graftBase.parsedOutline.nodes.map((node) => [node.ref, node.wireRef]));
const graftMaxBefore = Math.max(...graftBase.parsedOutline.nodes.map((node) => Number(/^@e(\d+)$/.exec(node.ref)?.[1] ?? 0)));
const grafted = graftScopedOutline(graftBase.parsedOutline, graftTargetRef, scopedLook.parsedOutline);
assert.equal(grafted.ref, graftTargetRef, "graft renamed the element that was expanded");
for (const [ref, wireRef] of graftBefore) {
	assert.equal(nodeByRef(graftBase.parsedOutline, ref)?.wireRef, wireRef, `graft lost the pre-existing ref ${ref}`);
}
for (const node of graftBase.parsedOutline.nodes) {
	if (graftBefore.has(node.ref)) continue;
	assert(Number(/^@e(\d+)$/.exec(node.ref)?.[1] ?? 0) > graftMaxBefore, `grafted node reused a ref number: ${node.ref}`);
}
assert.equal(grafted.children.length, 2, "graft did not adopt the scoped children");

const editor = nextLook.parsedOutline.nodes.find((node) => node.wireRef === "editor");
assert(editor, "editor fixture was not parsed");
const actionEnv = {
	headless: false,
	image: { width: 800, height: 600 },
	node: (ref) => nodeByRef(nextLook.parsedOutline, ref),
	center: (node) => ({ x: node.rect?.x ?? 0, y: node.rect?.y ?? 0 }),
	validatePoint: () => undefined,
};
const preparedClick = prepareAction({ action: "click", ref: editor.ref }, { currentFocus: false }, actionEnv);
assert.equal(preparedClick.params.button, "left", "omitted click.button did not default to left");
assert.equal(preparedClick.params.clickCount, 1, "omitted click.clickCount did not default to one");
assert.equal(preparedClick.establishesFocus, true, "editable semantic clicks should establish transaction focus");
// The element identity survives into the helper, which is what lets the outcome be judged
// on the element itself; the helper decides that a text role needs real pointer input.
assert.deepEqual(preparedClick.target, { ref: editor.wireRef }, "text-input clicks lost the element the outcome is judged on");
const pictureTarget = { ...editor, ref: "@e-picture", wireRef: undefined, isTextInput: false, pictureOnly: true };
const pictureClick = prepareAction({ action: "click", ref: pictureTarget.ref }, { currentFocus: false }, { ...actionEnv, node: () => pictureTarget });
assert.equal(pictureClick.needsForeground, true, "picture-only clicks should use foreground pointer delivery");
const preparedType = prepareAction({ action: "typeText", text: "hello" }, { currentFocus: true }, actionEnv);
assert.equal(preparedType.usesCurrentFocus, true, "focused typing did not preserve click-established focus");
const preparedScroll = prepareAction({ action: "scroll", ref: editor.ref }, { currentFocus: false }, actionEnv);
assert.deepEqual(preparedScroll.params, { scrollX: 0, scrollY: 0 }, "omitted scroll deltas did not default to zero");
const preparedWait = prepareAction({ action: "wait" }, { currentFocus: false }, actionEnv);
assert.deepEqual(preparedWait.params, { ms: 1_000 }, "omitted wait.ms did not default to 1000ms");
assert.equal(canRetryInForeground(preparedType, "didnt", false), true, "side-effect-free failed typing should retry in the foreground");
assert.equal(canRetryInForeground(preparedClick, "unknown", false), false, "ambiguous pointer actions must not be replayed");
assert.equal(outcomeAfterCheck("unknown", "verified"), "worked", "newly verified evidence did not prove the request worked");
assert.equal(outcomeAfterCheck("unknown", "preexisting"), "unknown", "preexisting evidence incorrectly proved the request worked");
assert.equal(outcomeAfterCheck("worked", "failed"), "didnt", "failed verification did not override delivery success");
assert.equal(outcomeAfterObservedValues("didnt", [{ action: "setText", ref: "@e1", text: "saved" }], () => "saved"), "worked", "resulting state did not override stale immediate setText evidence");
assert.equal(outcomeAfterObservedValues("didnt", [{ action: "setText", ref: "@e1", text: "saved" }], () => "old"), "didnt", "mismatched resulting value incorrectly proved setText worked");

const scheduler = new ResourceScheduler();
let active = 0;
let peak = 0;
const work = async () => {
	active += 1;
	peak = Math.max(peak, active);
	await sleep(25);
	active -= 1;
};
await Promise.all([
	scheduler.read("pid:1", work),
	scheduler.read("pid:2", work),
]);
assert.equal(peak, 2, "different resources did not overlap");

active = 0;
peak = 0;
await Promise.all([
	scheduler.read("pid:3", work),
	scheduler.read("pid:3", work),
]);
assert.equal(peak, 1, "same-resource operations overlapped");

await scheduler.write("pid:4", 0, async () => undefined);
await assert.rejects(
	() => scheduler.readAt("pid:4", 0, async () => undefined),
	(error) => error instanceof StaleResourceStateError,
);
await assert.rejects(
	() => scheduler.write("pid:4", 0, async () => undefined),
	(error) => error instanceof StaleResourceStateError,
);

await scheduler.close();

const rootFixture = (overrides) => ({
	windowId: 1,
	rootRef: "w1",
	title: "Input",
	zOrder: 5,
	isModal: false,
	isFocused: false,
	isMain: true,
	isMinimized: false,
	isOnscreen: true,
	...overrides,
});
assert.equal(
	shouldPreferForegroundModalWindow(rootFixture({}), rootFixture({ windowId: 2, rootRef: "w2", title: "Main", zOrder: 20, isModal: true })),
	false,
	"a modal root behind the requested one was promoted",
);
assert.equal(
	shouldPreferForegroundModalWindow(rootFixture({}), rootFixture({ windowId: 3, rootRef: "w3", title: "Prompt", zOrder: 2, isModal: true })),
	true,
	"a modal root in front of the requested one was not promoted",
);

assert.throws(
	() => ensurePermissions({ accessibility: false, screenRecording: true }, ["accessibility", "screenRecording"], "Permissions are required."),
	(error) => error?.code === "permission_missing" && error.message.includes("bcu setup"),
	"missing permissions must fail non-interactively with setup guidance",
);

const previousHeadless = process.env.BCU_HEADLESS;
try {
	process.env.BCU_HEADLESS = "1";
	const loaded = loadComputerUseConfig();
	assert.equal(loaded.sources.length, 1, "config must have one file source");
	assert.equal(loaded.sources[0].path, path.join(os.homedir(), ".config", "bcu", "config.json"));
	assert.equal(loaded.config.headless, true, "BCU_* environment variables must override the config file");
} finally {
	if (previousHeadless === undefined) delete process.env.BCU_HEADLESS;
	else process.env.BCU_HEADLESS = previousHeadless;
	loadComputerUseConfig();
}

console.log("PASS runtime units: state store, scheduler epochs, actions, diffs, root selection, config and permissions");
