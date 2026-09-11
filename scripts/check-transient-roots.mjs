#!/usr/bin/env node
// Transient roots — menus, sheets and popovers — have no stable window id. They are
// only reachable through the helper's root reference, so this gate observes and acts
// on a real menu and a real save sheet.
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

/** Apple, application, File — pressing by index keeps the probe independent of the system language. */
const FILE_MENU_BAR_INDEX = 2;
const fixtureDirectory = await makeTemporaryRoot("transient-roots");
const fixturePath = path.join(fixtureDirectory, `bcu-transient-${randomUUID()}.txt`);
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
	"func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {",
	"  var value: CFTypeRef?",
	"  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil",
	"}",
	"func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? [] }",
	"func windows() -> [AXUIElement] { attribute(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? [] }",
	"var observer: AXObserver?",
	"let callback: AXObserverCallback = { _, _, _, _ in ready() }",
	"guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { exit(3) }",
	"func observe(_ notification: String) {",
	"  let added = AXObserverAddNotification(observer, app, notification as CFString, nil)",
	"  guard added == .success || added == .notificationAlreadyRegistered else { exit(4) }",
	"}",
	"CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)",
	"DispatchQueue.global().asyncAfter(deadline: .now() + 12) { exit(2) }",
];

/** Activates the app, presses a menu bar item and resolves on AXMenuOpened. */
async function openMenuBarMenu(pid, index, processExited) {
	await runSwiftReadyProbe([
		...AX_PRELUDE,
		"observe(kAXMenuOpenedNotification as String)",
		"func pressMenuBarItem() {",
		"  guard let bar = attribute(app, kAXMenuBarAttribute as String) else { exit(5) }",
		"  let items = children(bar as! AXUIElement)",
		`  guard items.count > ${index} else { exit(6) }`,
		`  guard AXUIElementPerformAction(items[${index}], kAXPressAction as CFString) == .success else { exit(7) }`,
		"}",
		"guard let running = NSRunningApplication(processIdentifier: pid) else { exit(8) }",
		"if running.isActive { pressMenuBarItem() } else {",
		"  NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in",
		"    let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication",
		"    if activated?.processIdentifier == pid { pressMenuBarItem() }",
		"  }",
		"  running.activate()",
		"}",
		"RunLoop.main.run()",
	], [pid], "the TextEdit File menu to open", { abortedBy: processExited });
}

async function waitForWindowCount(pid, count, processExited) {
	await runSwiftReadyProbe([
		...AX_PRELUDE,
		"observe(\"AXWindowCreated\")",
		`if windows().count >= ${count} { ready() }`,
		"RunLoop.main.run()",
	], [pid], `TextEdit to expose ${count} Accessibility windows`, { abortedBy: processExited });
}

async function waitForSheet(pid, processExited) {
	await runSwiftReadyProbe([
		...AX_PRELUDE,
		"observe(\"AXSheetCreated\")",
		"if windows().contains(where: { !(attribute($0, kAXSheetsAttribute as String) as? [AXUIElement] ?? []).isEmpty }) { ready() }",
		"RunLoop.main.run()",
	], [pid], "the TextEdit save sheet", { abortedBy: processExited });
}

async function rootsOfKind(pid, kind) {
	const found = await brokerRequest("find-roots", { pid, kind });
	return found.roots.filter((candidate) => candidate.pid === pid && candidate.kind === kind);
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
	await waitForAxWindow(createdPid, processMonitor.exited);

	// A menu root: no stable window id, reachable only through the helper root reference.
	await openMenuBarMenu(createdPid, FILE_MENU_BAR_INDEX, processMonitor.exited);
	const menus = await rootsOfKind(createdPid, "menu");
	assert.equal(menus.length, 1, `expected exactly one open TextEdit menu root, got ${menus.length}`);

	const menuObserved = await brokerRequest("observe-ui", { root: menus[0].ref, mode: "semantic" });
	assert.equal(menuObserved.root.ref, menus[0].ref, "observe-ui returned another root than the open menu");
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
	await waitForWindowCount(createdPid, 2, processMonitor.exited);

	// A sheet root: TextEdit only raises the save sheet for a dirty untitled document.
	const untitled = (await rootsOfKind(createdPid, "window")).find((candidate) => candidate.title !== path.basename(fixturePath));
	assert(untitled, "pressing the first File menu item did not produce a second TextEdit window");
	const untitledObserved = await brokerRequest("observe-ui", { root: untitled.ref, mode: "semantic" });
	const editor = untitledObserved.nodes.find((node) => node.caps.includes("setText"));
	assert(editor, "the new TextEdit window did not expose an editable element");
	const typed = await brokerRequest("act-ui", {
		stateId: untitledObserved.stateId,
		actions: [{ action: "setText", ref: editor.ref, text: `bcu sheet fixture ${randomUUID()}` }],
	});
	await brokerRequest("act-ui", {
		stateId: typed.stateId,
		actions: [{ action: "keypress", keys: ["cmd+w"] }],
	});
	await waitForSheet(createdPid, processMonitor.exited);

	const sheets = await rootsOfKind(createdPid, "sheet");
	assert.equal(sheets.length, 1, `expected exactly one TextEdit save sheet root, got ${sheets.length}`);
	const sheetObserved = await brokerRequest("observe-ui", { root: sheets[0].ref, mode: "semantic" });
	assert.equal(sheetObserved.root.ref, sheets[0].ref, "observe-ui returned another root than the save sheet");
	const sheetButtons = sheetObserved.nodes.filter((node) => node.role === "button" && node.caps.includes("press"));
	assert(sheetButtons.length >= 2, `expected the save sheet to expose its buttons, got ${sheetButtons.length}`);
	await assertReadableActions(sheetObserved.stateId, sheetButtons.slice(0, 3).map((node) => node.ref));

	console.log(`PASS menu root observe → press '${newDocumentItem.name}' → sheet root observe in isolated pid ${createdPid}`);
} finally {
	if (createdPid) await stopTextEdit(createdPid, processMonitor);
	await fs.rm(fixtureDirectory, { recursive: true, force: true });
}
