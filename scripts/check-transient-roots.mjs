#!/usr/bin/env node
// Roots without a window id — the menu bar, open menus and sheets — are reachable only
// through the helper's root reference. This gate drives one real chain end to end: list the
// menu bar, press a menu bar item, follow the menu root the action reports, press an item in
// it, and observe the sheet that the document work then raises.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { brokerRequest, buildBundle, launchTextEdit, makeTemporaryRoot, monitorProcess, runSwiftReadyProbe, stopTextEdit, waitForAxWindow } from "./lib/harness.mjs";

if (process.env.BCU_LIVE !== "1") {
	console.log("SKIP transient roots (set BCU_LIVE=1)");
	process.exit(0);
}
if (process.platform !== "darwin") throw new Error("The transient root test requires macOS.");

/** Apple, application, File — pressing by index keeps probes independent of the system language. */
const FILE_MENU_BAR_INDEX = 2;
const fixtureDirectory = await makeTemporaryRoot("transient-roots");
const fixturePath = path.join(fixtureDirectory, `bcu-transient-${randomUUID()}.txt`);
const fixtureTitle = path.basename(fixturePath, ".txt");
let createdPid;
let processMonitor;

const AX_PRELUDE = [
	"import AppKit",
	"import ApplicationServices",
	"import Foundation",
	"import Darwin",
	"let pid = pid_t(CommandLine.arguments[1])!",
	"let app = AXUIElementCreateApplication(pid)",
	"func ready() { print(\"ready\"); fflush(stdout); exit(0) }",
	"func fail(_ reason: String) -> Never { fputs(reason + \"\\n\", stderr); exit(1) }",
	"func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {",
	"  var value: CFTypeRef?",
	"  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil",
	"}",
	"func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? [] }",
	"func windows() -> [AXUIElement] { attribute(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? [] }",
	"var observer: AXObserver?",
	"let callback: AXObserverCallback = { _, _, _, _ in ready() }",
	"guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { fail(\"could not observe the app\") }",
	"func observe(_ notification: String) {",
	"  let added = AXObserverAddNotification(observer, app, notification as CFString, nil)",
	"  guard added == .success || added == .notificationAlreadyRegistered else { fail(\"could not subscribe to \" + notification) }",
	"}",
	"CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)",
	"DispatchQueue.global().asyncAfter(deadline: .now() + 12) { fail(\"timed out; frontmost is \\(NSWorkspace.shared.frontmostApplication?.localizedName ?? \"none\"), windows=\\(windows().count)\") }",
	`let FILE_MENU = ${FILE_MENU_BAR_INDEX}`,
];

/** A menu item only takes effect in the app that owns the menu bar, so probes activate first. */
const ACTIVATE_THEN = (action) => [
	"guard let running = NSRunningApplication(processIdentifier: pid) else { fail(\"the app is gone\") }",
	`if running.isActive { ${action}() } else {`,
	"  NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in",
	"    let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication",
	`    if activated?.processIdentifier == pid { ${action}() }`,
	"  }",
	"  running.activate()",
	"}",
];

/**
 * TextEdit replaces an unmodified document window rather than adding one, so the new
 * document is recognised by title, not by a growing window count.
 */
async function waitForUntitledWindow(pid, fixtureTitle, processExited) {
	await runSwiftReadyProbe([
		...AX_PRELUDE,
		"func titles() -> [String] { windows().map { (attribute($0, kAXTitleAttribute as String) as? String) ?? \"\" } }",
		`func readyIfPresent() { if titles().contains(where: { !$0.hasPrefix(${JSON.stringify(fixtureTitle)}) && !$0.isEmpty }) { ready() } }`,
		"observe(\"AXWindowCreated\")",
		"observe(\"AXFocusedWindowChanged\")",
		"readyIfPresent()",
		"RunLoop.main.run()",
	], [pid], "TextEdit to open a new document", { abortedBy: processExited });
}

/**
 * Saving a document that was never saved is what makes TextEdit raise its save sheet.
 * The menu item is found by keyboard shortcut, the one label-free identity a menu item has,
 * so the fixture does not depend on the system language.
 */
async function raiseSaveSheet(pid, processExited) {
	await runSwiftReadyProbe([
		...AX_PRELUDE,
		"func menuItem(_ barIndex: Int, _ character: String, _ modifiers: Int) -> AXUIElement? {",
		"  guard let bar = attribute(app, kAXMenuBarAttribute as String) else { return nil }",
		"  let items = children(bar as! AXUIElement)",
		"  guard items.count > barIndex, let menu = children(items[barIndex]).first else { return nil }",
		"  return children(menu).first {",
		"    (attribute($0, \"AXMenuItemCmdChar\") as? String) == character",
		"      && (attribute($0, \"AXMenuItemCmdModifiers\") as? NSNumber)?.intValue == modifiers",
		"  }",
		"}",
		"func press(_ barIndex: Int, _ character: String, _ modifiers: Int, _ label: String) {",
		"  guard let entry = menuItem(barIndex, character, modifiers) else { fail(\"no \\(label) menu item\") }",
		"  guard AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success else { fail(\"pressing \\(label) failed\") }",
		"}",
		"func hasSheet() -> Bool { windows().contains { !(attribute($0, \"AXSheets\") as? [AXUIElement] ?? []).isEmpty } }",
		"var saving = false",
		// The menu item only takes effect while its menu is open, so Save is pressed from
		// the AXMenuOpened callback rather than straight after opening the menu.
		"let progress: AXObserverCallback = { _, _, notification, _ in",
		"  if (notification as String) == \"AXSheetCreated\" || hasSheet() { ready() }",
		"  if (notification as String) == \"AXMenuOpened\" && !saving { saving = true; press(FILE_MENU, \"S\", 0, \"Save\") }",
		"}",
		"var sequencer: AXObserver?",
		"guard AXObserverCreate(pid, progress, &sequencer) == .success, let sequencer else { fail(\"could not sequence the fixture\") }",
		"for notification in [\"AXMenuOpened\", \"AXSheetCreated\"] {",
		"  let added = AXObserverAddNotification(sequencer, app, notification as CFString, nil)",
		"  guard added == .success || added == .notificationAlreadyRegistered else { fail(\"could not subscribe to \" + notification) }",
		"}",
		"CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(sequencer), .commonModes)",
		"func openFileMenu() {",
		"  guard let bar = attribute(app, kAXMenuBarAttribute as String) else { fail(\"the app exposes no menu bar\") }",
		"  let barItems = children(bar as! AXUIElement)",
		"  guard barItems.count > FILE_MENU else { fail(\"the menu bar has only \\(barItems.count) items\") }",
		"  guard AXUIElementPerformAction(barItems[FILE_MENU], kAXPressAction as CFString) == .success else { fail(\"opening the File menu failed\") }",
		"}",
		...ACTIVATE_THEN("openFileMenu"),
		"RunLoop.main.run()",
	], [pid], "the TextEdit save sheet", { abortedBy: processExited });
}

async function rootsOfKind(pid, kind) {
	const found = await brokerRequest("find-roots", { pid, kind });
	return found.roots.filter((candidate) => candidate.pid === pid && candidate.kind === kind);
}

/** Leaves no unsaved document behind, which macOS would otherwise restore into later runs. */
async function dismissSheets(pid) {
	await runSwiftReadyProbe([
		...AX_PRELUDE,
		"for window in windows() {",
		"  for sheet in (attribute(window, \"AXSheets\") as? [AXUIElement] ?? []) {",
		"    _ = AXUIElementPerformAction(sheet, kAXCancelAction as CFString)",
		"  }",
		"}",
		"ready()",
	], [pid], "the TextEdit sheets to be dismissed");
}

/** The projection hides raw action names, so the helper's own output is the subject here. */
async function assertReadableActions(stateId, refs) {
	for (const ref of refs) {
		const inspected = await brokerRequest("inspect-ui", { stateId, ref });
		for (const action of inspected.node.actions ?? []) {
			assert(!action.includes("\n") && !action.includes("Target:0x"), `helper reported an unreadable action name ${JSON.stringify(action)}`);
		}
	}
}

try {
	await buildBundle();
	await fs.writeFile(fixturePath, "bcu transient root fixture\n");
	createdPid = await launchTextEdit(fixturePath);
	processMonitor = await monitorProcess(createdPid);
	await waitForAxWindow(createdPid, processMonitor.exited, fixtureTitle);

	// The menu bar: a root with no window id at all, and the way into every app command.
	const menuBars = await rootsOfKind(createdPid, "menubar");
	assert.equal(menuBars.length, 1, `expected exactly one TextEdit menu bar root, got ${menuBars.length}`);
	assert.equal(menuBars[0].windowId, undefined, "the menu bar root claims a window id it does not have");
	const barObserved = await brokerRequest("observe-ui", { root: menuBars[0].ref, mode: "semantic" });
	const barItems = barObserved.nodes.filter((node) => node.role === "menuitem" && node.depth === 1);
	assert(barItems.length > FILE_MENU_BAR_INDEX, `expected a populated menu bar, got ${barItems.length} items`);
	const fileItem = barItems[FILE_MENU_BAR_INDEX];
	assert(fileItem.caps.includes("press"), `the menu bar item '${fileItem.name}' cannot be pressed`);

	// Pressing it opens a menu root, and the action itself hands that root over: an agent
	// never has to race find-roots for a root its own action created.
	const openedMenu = await brokerRequest("act-ui", { stateId: barObserved.stateId, actions: [{ action: "press", ref: fileItem.ref }] });
	assert.equal(openedMenu.outcome, "worked", `pressing menu bar item '${fileItem.name}' did not work`);
	const menuRoot = (openedMenu.roots ?? []).find((root) => root.kind === "menu");
	assert(menuRoot, `pressing '${fileItem.name}' reported no menu root: ${JSON.stringify(openedMenu.roots)}`);

	const menuObserved = await brokerRequest("observe-ui", { root: menuRoot.ref, mode: "semantic" });
	assert.equal(menuObserved.root.ref, menuRoot.ref, "observe-ui returned another root than the menu the action opened");
	const menuItems = menuObserved.nodes.filter((node) => node.role === "menuitem" && node.name);
	assert(menuItems.length >= 5, `expected a populated File menu, got ${menuItems.length} named items`);
	const newDocumentItem = menuItems[0];
	assert(newDocumentItem.caps.includes("press"), `the first File menu item '${newDocumentItem.name}' cannot be pressed`);
	await assertReadableActions(menuObserved.stateId, menuItems.slice(0, 5).map((node) => node.ref));

	const pressed = await brokerRequest("act-ui", {
		stateId: menuObserved.stateId,
		actions: [{ action: "press", ref: newDocumentItem.ref }],
	});
	assert.equal(pressed.outcome, "worked", `pressing menu item '${newDocumentItem.name}' did not work`);
	await waitForUntitledWindow(createdPid, fixtureTitle, processMonitor.exited);
	const windowRefs = new Set((await rootsOfKind(createdPid, "window")).map((root) => root.ref));

	// A sheet root. Raising it is fixture work, not the subject: input delivery already has
	// its own gate, so the sheet is raised through Accessibility. Duplicating the fixture
	// yields an unsaved document, and closing that is what makes TextEdit ask to save.
	await raiseSaveSheet(createdPid, processMonitor.exited);

	const sheets = await rootsOfKind(createdPid, "sheet");
	assert.equal(sheets.length, 1, `expected exactly one TextEdit save sheet root, got ${sheets.length}`);
	const sheetObserved = await brokerRequest("observe-ui", { root: sheets[0].ref, mode: "semantic" });
	assert.equal(sheetObserved.root.ref, sheets[0].ref, "observe-ui returned another root than the save sheet");
	const sheetButtons = sheetObserved.nodes.filter((node) => node.role === "button" && node.caps.includes("press"));
	assert(sheetButtons.length >= 2, `expected the save sheet to expose its buttons, got ${sheetButtons.length}`);
	await assertReadableActions(sheetObserved.stateId, sheetButtons.slice(0, 3).map((node) => node.ref));
	assert(!windowRefs.has(sheets[0].ref), "the sheet root is not distinguished from the window behind it");

	console.log(`PASS menu bar root → press '${fileItem.name}' → menu root from the action → press '${newDocumentItem.name}' → sheet root in isolated pid ${createdPid}`);
} finally {
	if (createdPid) {
		await dismissSheets(createdPid).catch(() => undefined);
		await stopTextEdit(createdPid, processMonitor);
	}
	await fs.rm(fixtureDirectory, { recursive: true, force: true });
}
