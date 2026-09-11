import { execFileSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import typescript from "typescript";
import { HELPER_PROTOCOL_VERSION } from "../src/macos/helper.ts";
import { graftScopedOutline, nodeByRef, parseLookResponse } from "../src/outline.ts";
import { CAPABILITIES, project, renderObservation } from "../src/projection.ts";
import { shouldPreferForegroundModalWindow } from "../src/root-selection.ts";

const root = fileURLToPath(new URL("..", import.meta.url));
const swift = fs.readFileSync(path.join(root, "native/macos/bridge.swift"), "utf8");
const agentCursorSwift = fs.readFileSync(path.join(root, "native/macos/agent_cursor.swift"), "utf8");
const toolModuleFiles = ["src/session.ts", "src/roots.ts", "src/observe.ts", "src/act.ts"];
const toolModules = Object.fromEntries(toolModuleFiles.map((file) => [file, fs.readFileSync(path.join(root, file), "utf8")]));
const ts = toolModuleFiles.map((file) => toolModules[file]).join("\n");
const configTs = fs.readFileSync(path.join(root, "src/config.ts"), "utf8");
const contractTs = fs.readFileSync(path.join(root, "src/contract.ts"), "utf8");
const cliTs = fs.readFileSync(path.join(root, "src/cli.ts"), "utf8");
const brokerTs = fs.readFileSync(path.join(root, "src/broker.ts"), "utf8");
const setupHelper = fs.readFileSync(path.join(root, "scripts/setup-helper.mjs"), "utf8");
const macosHelperPath = fs.readFileSync(path.join(root, "src/macos/helper-path.mjs"), "utf8");
const srcFiles = fs.readdirSync(path.join(root, "src"), { recursive: true })
	.filter((file) => typeof file === "string" && file.endsWith(".ts"))
	.map((file) => [file, fs.readFileSync(path.join(root, "src", file), "utf8")]);
const scriptFiles = fs.readdirSync(path.join(root, "scripts"), { recursive: true })
	.filter((file) => typeof file === "string" && file.endsWith(".mjs"))
	.map((file) => [`scripts/${file}`, fs.readFileSync(path.join(root, "scripts", file), "utf8")]);
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

check("INV-1 static helper observation commands removed", () => {
	assert(!swift.includes("visionTargets"), "bridge.swift still contains visionTargets");
	assert(!swift.includes("axSnapshotTree"), "bridge.swift still contains axSnapshotTree");
	assert(!/case\s+"screenshot"/.test(swift), "bridge.swift still dispatches screenshot");
});

check("INV-1 static src lookCompat absent", () => {
	for (const [file, text] of srcFiles) {
		assert(!text.includes("lookCompat"), `lookCompat appears in src/${file}`);
	}
});

check("INV-2 static no TS coordinate transforms or capture dimensions", () => {
	for (const [file, text] of srcFiles) {
		assert(!/screenPointToCapturePoint|screenFrameToCaptureFrame/.test(text), `coordinate transform appears in src/${file}`);
		assert(!/\bcaptureWidth\b|\bcaptureHeight\b/.test(text), `capture dimensions appear in src/${file}`);
	}
});

check("INV-3 static scene fusion and auto-confirm absent", () => {
	for (const [file, text] of srcFiles) {
		assert(!/sceneAxTargetsFromSemantic|buildSceneProjection|autoConfirmButton|coordinateStateSignature/.test(text), `deleted scene/confirm helper appears in src/${file}`);
	}
});

check("INV-4 static act owns input command surface", () => {
	assert(srcFiles.some(([, text]) => /interface HelperActResult[\s\S]*outcome: ActOutcome/.test(text)), "TS helper act result does not carry outcome");
	for (const [file, text] of srcFiles) {
		assert(!/verifiedCoordinateClick|coordinateStateSignature/.test(text), `deleted verification helper appears in src/${file}`);
	}
	const deletedCommands = [
		"mouseClick", "mouseMove", "mouseDrag", "scrollWheel", "keyPress", "typeText", "setValue", "selectText",
		"axClickElement", "axPerformActionElement", "axFocusElement", "axFocusAtPoint", "axClickAtPoint",
		"axFindTextInput", "axFocusTextInput", "axPressElement", "axPressAtPoint",
	];
	for (const command of deletedCommands) {
		assert(!new RegExp(`case\\s+"${command}"`).test(swift), `bridge.swift still dispatches ${command}`);
		assert(!new RegExp(`bridgeCommand(?:<[^>]+>)?\\(\\s*["']${command}["']`).test(ts), `src still calls helper command ${command}`);
	}
});

check("INV-8 deleted architecture-v1 identifiers absent", () => {
	const deletedSrcIdentifiers = [
		"SceneProjection", "SceneTarget", "SceneEdge", "SceneAssociation", "buildSceneProjection",
		"sceneAssociationScore", "labelAssociationScore", "bestEdgesByVision", "clusterVisionUnknowns",
		"semanticSceneTarget", "visionSceneTarget", "searchSceneTargets", "sceneAxTargetsFromSemantic",
		"parseVisionTargets", "visionTargetByRef", "visionClickPoint", "formatVisionTargetLabel",
		"axCoordinateFallbackPoint", "screenPointToCapturePoint", "screenFrameToCaptureFrame",
		"frameCenter", "frameArea", "intersectionArea", "coordinateStateSignature",
		"verifiedCoordinateClick", "mouseClickAtCapturePoint", "autoConfirmButton", "refreshAxTargets",
		"axTreeRawForTarget", "semanticAxTree", "helperVisionTargets", "currentSemanticAxTargets",
		"currentVisionTargets", "currentScene", "lookCompat", "SceneToolDetails", "ScreenshotParams",
		"ScreenshotPayload", "performScreenshot", "coordinateVerification", "coordinateStateChanged",
	];
	for (const [file, text] of srcFiles) {
		for (const identifier of deletedSrcIdentifiers) {
			assert(!text.includes(identifier), `${identifier} appears in src/${file}`);
		}
	}
	const deletedNativeIdentifiers = ["visionTargets", "axSnapshotTree", "reacquireAxTarget"];
	for (const identifier of deletedNativeIdentifiers) {
		assert(!swift.includes(identifier), `${identifier} appears in native/macos/bridge.swift`);
	}
});

check("INV-5 root contract carries modality as a fact and hints as metadata", () => {
	const protocol = fs.readFileSync(path.join(root, "src/macos/protocol.ts"), "utf8");
	assert(/interface HelperRoot[\s\S]*isModal: boolean/.test(protocol), "HelperRoot lacks required isModal fact");
	assert(/interface HelperRoot[\s\S]*metadata\?: Record<string, unknown>/.test(protocol), "HelperRoot lacks metadata escape hatch");
	assert(!/interface HelperRoot[\s\S]*\bpairing:/.test(protocol), "HelperRoot must not require pairing");
	assert(!/interface HelperRoot[\s\S]*\bsheetCount:/.test(protocol), "HelperRoot must not require sheetCount");
});

check("INV-5 macOS is the only platform surface", () => {
	const guards = [...cliTs.matchAll(/process\.platform !== "darwin"/g)].length;
	assert(guards === 1, `expected exactly one CLI platform guard, found ${guards}`);
	assert(/unsupported_platform/.test(cliTs), "CLI platform guard does not raise unsupported_platform");
});

check("explicit root is not replaced by a modal window behind it", () => {
	const root = (overrides) => ({
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
	const current = root({});
	const behindModal = root({ windowId: 2, rootRef: "w2", title: "Main", zOrder: 20, isModal: true });
	const foregroundModal = root({ windowId: 3, rootRef: "w3", title: "Prompt", zOrder: 2, isModal: true });
	assert(!shouldPreferForegroundModalWindow(current, behindModal), "modal root behind the explicit target was promoted");
	assert(shouldPreferForegroundModalWindow(current, foregroundModal), "foreground modal root was not promoted");
});

check("macOS ScreenCaptureKit config sizes window screenshots", () => {
	const captureFunction = swift.slice(swift.indexOf("private func captureWindow"), swift.indexOf("private func jpegData"));
	assert(/config\.width\s*=/.test(captureFunction), "captureWindow does not set SCStreamConfiguration.width");
	assert(/config\.height\s*=/.test(captureFunction), "captureWindow does not set SCStreamConfiguration.height");
});

check("INV-7 static no label-confirm press regex", () => {
	for (const [file, text] of srcFiles) {
		assert(!/\/[^/\n]*(confirm|ok|continue|apply)[^/\n]*\/[gimsuyd]*[\s\S]{0,200}(\bpress\b|AXPress|axPress|axPerformActionElement)/i.test(text), `confirm-label press regex appears in src/${file}`);
		assert(!/(confirm|ok|continue|apply)[\s\S]{0,80}(includes|startsWith|endsWith|===|==)[\s\S]{0,200}(\bpress\b|AXPress|axPress|axPerformActionElement)/i.test(text), `confirm-label press comparison appears in src/${file}`);
	}
});

check("INV-8 tsc no unused locals", () => {
	execFileSync(process.execPath, [path.join(root, "node_modules", "typescript", "bin", "tsc"), "--noEmit"], { cwd: root, stdio: "pipe" });
});

check("INV-9 immutable state ownership", () => {
	const state = fs.readFileSync(path.join(root, "src/state.ts"), "utf8");
	const runtime = fs.readFileSync(path.join(root, "src/runtime.ts"), "utf8");
	assert(!/runtimeState\.current(Target|Capture|Look|Outline|StateTarget)/.test(ts), "global current UI state remains in the tool modules");
	assert(state.includes("class SavedStates") && state.includes("new StateStore<UiObservation>"), "unified bounded observation store is missing");
	for (const gate of ["maxEntries", "maxBytes", "maxRecordBytes", "ttlMs"]) assert(runtime.includes(gate), `state store lacks ${gate} gate`);
	assert(!/image: state\.currentLook\.image \? \{ \.\.\.state\.currentLook\.image \}/.test(state), "saved state retains screenshot bytes");
});

check("INV-10 resource-keyed scheduling", () => {
	assert(ts.includes("desktopResourceKey") && ts.includes("resourceScheduler.write"), "desktop writes are not resource scheduled");
	assert(!ts.includes("withRuntimeLock"), "global runtime lock remains");
});

check("INV-11 unified CLI contract and bridge ownership", () => {
	const commands = [...cliTs.matchAll(/^\s*"([^"]+)": executor\("[^"]+"\),$/gm)].map((match) => match[1]);
	const expected = ["find-roots", "observe-ui", "search-ui", "expand-ui", "inspect-ui", "act-ui", "read-text", "wait-for"];
	assert(JSON.stringify(commands) === JSON.stringify(expected), `unexpected public CLI tool surface: ${commands.join(", ")}`);
	for (const command of expected) assert(contractTs.includes(`"${command}"`), `CLI parameter contract lacks ${command}`);
	assert(cliTs.includes("satisfies { [Name in CliCommandName]: CliCommandExecutor<Name> }"), "CLI command table is not type-checked against the contract");
	const sourceFiles = [
		...srcFiles.map(([file, text]) => [`src/${file}`, text]),
		...scriptFiles,
	];
	const toolModuleImports = new Set();
	for (const [file, text] of sourceFiles) {
		const source = typescript.createSourceFile(file, text, typescript.ScriptTarget.Latest, false, file.endsWith(".ts") ? typescript.ScriptKind.TS : typescript.ScriptKind.JS);
		const visit = (node) => {
			let specifier;
			if ((typescript.isImportDeclaration(node) || typescript.isExportDeclaration(node)) && node.moduleSpecifier && typescript.isStringLiteral(node.moduleSpecifier)) {
				specifier = node.moduleSpecifier.text;
			} else if (typescript.isCallExpression(node) && node.arguments.length === 1 && typescript.isStringLiteral(node.arguments[0])) {
				const dynamicImport = node.expression.kind === typescript.SyntaxKind.ImportKeyword;
				const requireCall = typescript.isIdentifier(node.expression) && node.expression.text === "require";
				if (dynamicImport || requireCall) specifier = node.arguments[0].text;
			}
			if (specifier && toolModuleFiles.some((module) => specifier.endsWith(`/${module.replace("src/", "")}`))) toolModuleImports.add(file);
			typescript.forEachChild(node, visit);
		};
		visit(source);
	}
	// Only the broker owns the tool runtime; everything else must go through IPC.
	const externalOwners = [...toolModuleImports].filter((file) => !toolModuleFiles.includes(file) && !file.startsWith("src/"));
	assert(externalOwners.length === 0, `unexpected tool-runtime owners outside the broker: ${externalOwners.join(", ")}`);
	assert(toolModuleImports.has("src/broker.ts"), "broker no longer owns the tool runtime");
	for (const command of expected) assert(brokerTs.includes(`case "${command}"`), `broker does not dispatch ${command}`);
	assert(cliTs.includes('await import("./broker.ts")'), "broker is not lazily loaded behind __serve");
});

check("INV-12 concurrent native transport", () => {
	assert(swift.includes("Thread.detachNewThread") && swift.includes("physicalInputLock"), "macOS helper is not concurrent with protected physical input");
	assert(swift.includes("flock(lockFile, LOCK_EX | LOCK_NB)"), "macOS helper daemon is not singleton-safe");
});

check("INV-14 native batches settle once", () => {
	assert(ts.includes("macosBackend.actBatch") && ts.includes("dispatchUiTransaction"), "act does not route batches through the native transaction seam");
	assert(swift.includes('case "actBatch"') && swift.includes("deferRootDelta"), "macOS helper does not defer per-step root deltas");
	assert(swift.includes('response["stoppedAt"]'), "native batches do not report their checked stop boundary");
});

check("INV-15 semantic action postconditions", () => {
	const actions = fs.readFileSync(path.join(root, "src/actions.ts"), "utf8");
	assert(contractTs.includes("expect?: Expectation") && contractTs.includes("timeoutMs?: number"), "act_ui does not expose a semantic postcondition");
	assert(ts.includes('throw new BcuError("action_failed"') && ts.includes('status: "verified"'), "postcondition failure is not represented honestly");
	assert(ts.includes("outcomeAfterCheck") && actions.includes('check === "verified"') && actions.includes('return "worked"'), "newly verified expectations do not determine the request outcome");
	assert(swift.includes("waitForRootChange") && swift.includes("state.change.broadcast()"), "macOS waits are not change-notification assisted");
});

check("INV-16 clean headless contract and non-destructive helper install", () => {
	assert(!/stealth_mode|stealthMode|BCU_STEALTH|BCU_STRICT_AX/.test(configTs), "obsolete stealth configuration aliases remain");
	assert(!/tccutil[\s\S]{0,80}reset|resetTcc/i.test(setupHelper), "helper installation can reset macOS privacy grants");
	assert(setupHelper.includes("bcu Local Signing (com.sugeh.bcu)"), "stable bundle-specific local signing identity is missing");
	assert(macosHelperPath.includes("BCU_HELPER_APP_PATH"), "helper installer lacks an isolated test destination");
	assert(setupHelper.includes("resolveMacosHelperAppPath"), "helper installer bypasses shared macOS path resolution");
});

check("INV-17 macOS agent cursor stays native, configurable, and background-only", () => {
	assert(configTs.includes("cursor_overlay: boolean") && configTs.includes("BCU_CURSOR_OVERLAY"), "agent cursor config is incomplete");
	assert(swift.includes('delivery == "pid"'), "physical cursor delivery can display the agent cursor");
	assert(swift.includes('policy != "ax_only"'), "strict-headless actions can display the agent cursor");
	assert(swift.includes('request["cursorOverlay"] as? Bool ?? true'), "native helper ignores the cursor overlay flag");
	assert(swift.includes("app.processIdentifier != getpid()"), "helper overlay can leak into root discovery");
	assert(swift.includes("AgentCursor.shared.animate(to:"), "native grounded actions do not drive the agent cursor");
	assert(!swift.includes("completed.wait()") && !swift.includes("agentCursorLock"), "agent cursor can delay action delivery");
	assert(agentCursorSwift.includes("paused: !renderer.isAnimating"), "agent cursor timeline continues rendering while idle");
});

check("INV-19 all timed waits are classified", () => {
	const helper = fs.readFileSync(path.join(root, "src/macos/helper.ts"), "utf8");
	const harness = fs.readFileSync(path.join(root, "scripts/lib/harness.mjs"), "utf8");
	const timedFiles = [
		...srcFiles.map(([file, text]) => [`src/${file}`, text]),
		...scriptFiles,
	];
	const rules = [
		["src/broker.ts", /idleTimer =/, "broker idle TTL"],
		["src/session.ts", /cleanup\(\);\s*resolve\(\)/, "abortable timer primitive"],
		["src/act.ts", /^await sleep\(prepared\.params\.ms/, "explicit desktop wait action"],
		["src/act.ts", /await sleep\(settleMsForExecution/, "action settle"],
		["src/readiness.ts", /options\.description/, "readiness failure timeout"],
		["src/macos/helper.ts", /Command timed out after/, "helper process timeout"],
		["src/macos/helper.ts", /old bcu helper to exit/, "helper exit timeout"],
		["src/macos/helper.ts", /Daemon command.*timed out/, "helper command timeout"],
		["scripts/check-invariants.mjs", /recentCompletedRequestIds\?\.includes/, "abandoned-request completion poll", 2],
		["scripts/setup-helper.mjs", /local signing identity lock/, "signing lock timeout"],
		["scripts/lib/harness.mjs", /Timed out waiting for/, "harness failure timeout"],
		["scripts/check-invariants.mjs", /timeout calling/, "live invariant call timeout", 2],
		["scripts/check-runtime-concurrency.mjs", /^const sleep =/, "scheduler test work"],
		["scripts/check-runtime-concurrency.mjs", /^await sleep\(25\)/, "scheduler test work"],
		["scripts/bench.mjs", /Timed out calling/, "benchmark call timeout"],
		["scripts/bench.mjs", /cold helper start/, "benchmark failure timeout"],
	].map(([file, pattern, category, expected = 1]) => ({ file, pattern, category, expected, count: 0 }));
	const sitePattern = /\bset(?:Timeout|Interval)\s*\(|await\s+(?:sleep|delay)\s*\(|while\s*\(\s*true\s*\)|Date\.now\(\)\s*</;
	const unclassified = [];
	for (const [file, text] of timedFiles) {
		const lines = text.split("\n");
		for (let index = 0; index < lines.length; index += 1) {
			if (!sitePattern.test(lines[index])) continue;
			const context = `${lines[index].trim()}\n${lines.slice(Math.max(0, index - 4), index + 5).join("\n")}`;
			const rule = rules.find((candidate) => candidate.file === file && candidate.pattern.test(context));
			if (!rule) unclassified.push(`${file}:${index + 1}: ${lines[index].trim()}`);
			else rule.count += 1;
		}
	}
	assert(unclassified.length === 0, `unclassified timed waits:\n${unclassified.join("\n")}`);
	for (const rule of rules) assert(rule.count === rule.expected, `${rule.file} ${rule.category} expected ${rule.expected}, found ${rule.count}`);
	assert(helper.includes("waitForPathReady"), "macOS helper does not wait on socket filesystem events");
	assert(setupHelper.includes("watch(directory)") && !setupHelper.includes("retryMs"), "signing lock is not event-driven");
	assert(harness.includes("AXObserverAddNotification") && harness.includes("NSWorkspace.shared.open") && harness.includes("makeProcessSource"), "live harness does not use launch, process, and AX events");
});

check("INV-18 consolidated actions and diff-first resulting views", () => {
	const actions = fs.readFileSync(path.join(root, "src/actions.ts"), "utf8");
	const view = fs.readFileSync(path.join(root, "src/view.ts"), "utf8");
	const macBackend = fs.readFileSync(path.join(root, "src/macos/backend.ts"), "utf8");
	assert(actions.includes("prepareAction") && actions.includes("canRetryInForeground"), "action preparation and safe recovery are not consolidated");
	assert(!ts.includes("responseMode") && !contractTs.includes("responseMode"), "alternate confirmation-only action path still exists");
	assert(ts.includes("currentFocus") && ts.includes('escalationReason = "side_effect_free_didnt"'), "runner does not preserve action focus or recover checked keyboard failures");
	assert(view.includes("stabilizeRefs") && view.includes("changesBetween"), "resulting-state ref stabilization or change rendering is missing");
	assert(ts.includes("successorView(baseNodes") && view.includes("useFullView"), "agent result does not expose changes-first resulting views");
	assert(contractTs.includes('action: "press" | "click"') && actions.includes("usesCurrentFocus"), "action contract is not explicit or focus-aware");
	assert(!ts.includes("preserveFocus") && macBackend.includes("preserveFocus") && swift.includes("!preserveFocus"), "native focus continuity leaks through the coordinator or is not enforced by the backend");
});

if (process.platform === "darwin") {
	check("INV-8 swift typecheck", () => {
		const triple = process.arch === "x64" ? "x86_64-apple-macosx14.0" : "arm64-apple-macosx14.0";
		execFileSync("xcrun", [
			"swiftc", "-target", triple, "-parse-as-library",
			"-module-cache-path", path.join(os.tmpdir(), `bcu-swift-typecheck-${process.arch}`),
			"-framework", "ApplicationServices",
			"-framework", "AppKit",
			"-framework", "ScreenCaptureKit",
			"-framework", "Foundation",
			"-framework", "SwiftUI",
			"-typecheck",
			"native/macos/agent_cursor.swift",
			"native/macos/agent_cursor_motion.swift",
			"native/macos/bridge.swift",
		], { cwd: root, stdio: "pipe" });
	});
} else {
	console.log("SKIP INV-8 swift typecheck (macOS only)");
}

check("INV-19 macOS root identity resolution", () => {
	assert(swift.includes("let requestedRoot = refStore.window(for: rootRef)"), "look does not resolve the root from the helper root reference");
	assert(swift.includes('let rootRef = try stringArg(request, "rootRef")'), "look treats the root reference as optional");
	assert(!swift.includes("windowRef"), "the helper still names a root reference after windows");
	assert(swift.includes("guard let pid = pidForElement(window) else"), "look cannot recover the owner pid from a stored native root");
	assert(swift.includes("guard let menuWindowId = cgMenuWindowId(rootRef), let menuPid = pidForWindowId(menuWindowId) else"), "look cannot observe a popup menu Accessibility never exposed");
	assert(!swift.includes("CGWindowListCopyWindowInfo([.optionIncludingWindow]"), "window lookup uses optionIncludingWindow without an above/below selector");
	assert(swift.includes("CGWindowListCreateDescriptionFromArray(requestedIds)"), "window lookup does not use the targeted window-description API");
	assert(swift.includes("CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)"), "window lookup does not fall back to all onscreen and offscreen windows");
	assert(swift.includes("($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowId"), "window lookup does not verify the returned stable ID");
});

check("INV-20 bounded broad root discovery", () => {
	assert(swift.includes("private func broadRootCandidateApps"), "macOS helper lacks a broad root-candidate preflight");
	assert(swift.includes("private func cgBroadRootOwners"), "macOS helper lacks a dedicated broad-owner preflight");
	assert(swift.includes("layer == 0 || layer == popupLevel"), "broad root discovery is not bounded by layer-0 and popup-menu owners");
	assert(swift.includes("bounds.width >= 100") && swift.includes("bounds.height >= 80"), "listApps no longer retains its established owner threshold");
	assert(!swift.includes("for owner in cgWindowOwners() + cgPopupMenuOwners()"), "listApps includes unrelated popup-owner expansion");
	assert(swift.includes("if let pid {\n\t\t\tapps = [[\"pid\": Int(pid)]]"), "explicit-pid root discovery no longer stays immediate");
	assert(swift.includes("popupCandidates.isEmpty ? [] : openMenuElements"), "root discovery traverses menus when no popup exists");
	assert(swift.includes("let menuPairings = windowPairings(windows: menuElements, candidates: popupCandidates)"), "open menus are not paired with popup windows by geometry");
	assert(swift.includes('== "AXMenu" && isOpenMenu($0)'), "menu discovery does not separate open menus from the closed menu tree");
	assert(swift.includes("signal(SIGPIPE, SIG_IGN)"), "helper daemon does not ignore process-wide SIGPIPE");
	assert(swift.includes("SO_NOSIGPIPE"), "helper sockets can terminate the daemon on a late response");
	assert(swift.includes("Darwin.send(responseSocket"), "helper socket responses do not use failure-tolerant writes");
	assert(swift.includes("recentCompletedRequestIds"), "helper diagnostics cannot establish abandoned-request completion");
});

check("INV-17 macOS agent cursor lifecycle", () => {
	const triple = process.arch === "x64" ? "x86_64-apple-macosx14.0" : "arm64-apple-macosx14.0";
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
});

function call(socketPath, payload, timeoutMs = 10000) {
	return new Promise((resolve, reject) => {
		const socket = net.createConnection(socketPath);
		let buffer = "";
		const timer = setTimeout(() => {
			socket.destroy();
			reject(new Error(`timeout calling ${payload.cmd}`));
		}, timeoutMs);
		socket.setEncoding("utf8");
		socket.on("connect", () => socket.write(`${JSON.stringify(payload)}\n`));
		socket.on("data", (chunk) => {
			buffer += chunk;
			const newline = buffer.indexOf("\n");
			if (newline < 0) return;
			clearTimeout(timer);
			socket.end();
			const parsed = JSON.parse(buffer.slice(0, newline));
			if (!parsed.ok) reject(new Error(parsed.error?.message ?? `${payload.cmd} failed`));
			else resolve(parsed.result);
		});
		socket.on("error", (error) => {
			clearTimeout(timer);
			reject(error);
		});
	});
}

function abandon(socketPath, payload) {
	return new Promise((resolve, reject) => {
		const socket = net.createConnection(socketPath);
		socket.on("connect", () => {
			socket.write(`${JSON.stringify(payload)}\n`, () => {
				socket.destroy();
				resolve();
			});
		});
		socket.on("error", reject);
	});
}

async function waitForCompletedRequest(socketPath, requestId, timeoutMs = 10000) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		const diagnostics = await call(socketPath, { id: `inv-completion-${Date.now()}`, cmd: "diagnostics" });
		if (diagnostics.recentCompletedRequestIds?.includes(requestId)) return diagnostics;
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
	throw new Error(`request ${requestId} did not complete within ${timeoutMs}ms`);
}

function callEnvelope(socketPath, payload, timeoutMs = 10000) {
	return new Promise((resolve, reject) => {
		const socket = net.createConnection(socketPath);
		let buffer = "";
		const timer = setTimeout(() => {
			socket.destroy();
			reject(new Error(`timeout calling ${payload.cmd}`));
		}, timeoutMs);
		socket.setEncoding("utf8");
		socket.on("connect", () => socket.write(`${JSON.stringify(payload)}\n`));
		socket.on("data", (chunk) => {
			buffer += chunk;
			const newline = buffer.indexOf("\n");
			if (newline < 0) return;
			clearTimeout(timer);
			socket.end();
			resolve(JSON.parse(buffer.slice(0, newline)));
		});
		socket.on("error", (error) => {
			clearTimeout(timer);
			reject(error);
		});
	});
}

function walk(node, visit) {
	visit(node);
	for (const child of Array.isArray(node?.children) ? node.children : []) walk(child, visit);
}

function windowLabel(window) {
	if (!window) return "unknown window";
	return `${window.appName ?? window.app ?? "unknown app"} — ${window.title ?? window.windowTitle ?? "(untitled)"} (${window.windowId ?? "no windowId"})`;
}

async function pidForWindow(socketPath, windowId) {
	const apps = await call(socketPath, { id: "inv-apps", cmd: "listApps" });
	for (const app of Array.isArray(apps) ? apps : []) {
		const windows = ((await call(socketPath, { id: `inv-roots-${app.pid}`, cmd: "listRoots", pid: app.pid }).catch(() => ({ roots: [] }))).roots) ?? [];
		const match = Array.isArray(windows) ? windows.find((window) => window?.windowId === windowId) : undefined;
		if (match) return { pid: app.pid, appName: app.appName, title: match.title ?? match.windowTitle };
	}
	return undefined;
}

async function liveChecks() {
	if (process.env.BCU_LIVE !== "1") {
		console.log("SKIP LIVE invariants (set BCU_LIVE=1)");
		return;
	}
	try {
		const socketPath = process.env.BCU_SOCKET_PATH ?? path.join(os.homedir(), "Library/Caches/bcu/bridge.sock");
		const diagnostics = await call(socketPath, { id: "inv-diagnostics", cmd: "diagnostics" });
		check("LIVE diagnostics current protocol", () => assert(diagnostics.protocolVersion === HELPER_PROTOCOL_VERSION, `protocolVersion=${diagnostics.protocolVersion}`));
		const broadDiscoveryStarted = Date.now();
		const broadRoots = await call(socketPath, { id: "inv-broad-roots", cmd: "listRoots" }, 10000);
		const broadDiscoveryMs = Date.now() - broadDiscoveryStarted;
		const diagnosticsAfterBroadDiscovery = await call(socketPath, { id: "inv-diagnostics-after-broad-roots", cmd: "diagnostics" });
		check("LIVE broad root discovery is bounded and keeps helper alive", () => {
			assert(Array.isArray(broadRoots?.roots), "broad listRoots did not return roots");
			assert(broadDiscoveryMs < 10000, `broad listRoots took ${broadDiscoveryMs}ms`);
			assert(diagnosticsAfterBroadDiscovery.protocolVersion === HELPER_PROTOCOL_VERSION, "helper did not survive broad listRoots");
		});
		const abandonedRequestId = `inv-abandoned-roots-${process.pid}-${Date.now()}`;
		await abandon(socketPath, { id: abandonedRequestId, cmd: "listRoots" });
		const diagnosticsAfterAbandon = await waitForCompletedRequest(socketPath, abandonedRequestId);
		check("LIVE abandoned root discovery keeps helper alive", () => {
			assert(diagnosticsAfterAbandon.protocolVersion === HELPER_PROTOCOL_VERSION, "helper died after writing to an abandoned root-discovery socket");
		});
		const explicitRootRef = process.env.BCU_LIVE_ROOT_REF || undefined;
		let windows = [];
		try {
			const frontmost = await call(socketPath, { id: "inv-frontmost", cmd: "getFrontmost" });
			windows = ((await call(socketPath, { id: "inv-roots", cmd: "listRoots", pid: frontmost.pid })).roots) ?? [];
			check("LIVE listRoots pairing", () => {
				assert(Array.isArray(windows), "listRoots did not return an array");
				for (const window of windows) {
					assert(["exact", "high", "low"].includes(window?.metadata?.pairing?.confidence), `invalid pairing ${JSON.stringify(window?.metadata?.pairing)}`);
				}
			});
		} catch (error) {
			if (!explicitRootRef) throw error;
			console.log(`SKIP LIVE listRoots pairing (${error.message}; explicit BCU_LIVE_ROOT_REF=${explicitRootRef})`);
		}
		let target = explicitRootRef
			? { rootRef: explicitRootRef, title: "BCU_LIVE_ROOT_REF", appName: "explicit target" }
			: Array.isArray(windows) ? windows.find((window) => window?.rootRef && Number.isFinite(window?.windowId)) : undefined;
		if (!target) {
			console.log("SKIP LIVE look (no capturable frontmost window; Accessibility may be missing)");
			return;
		}
		const look = await call(socketPath, { id: "inv-look", cmd: "look", rootRef: target.rootRef, windowId: target.windowId, readText: "always" }, 20000);
		if (explicitRootRef) {
			target = { ...target, ...look.window, title: look.window?.title ?? target.title };
		}
		const pidInfo = await pidForWindow(socketPath, target.windowId);
		if (pidInfo) {
			target = { ...target, ...pidInfo, appName: pidInfo.appName ?? target.appName, title: pidInfo.title ?? target.title };
		}
		check("LIVE look one moment", () => {
			assert(typeof look.capturedAt === "number", "missing capturedAt");
			assert(look.image && look.outline, "missing image or outline");
		});
		check("LIVE rects within image", () => {
			walk(look.outline, (node) => {
				const rect = node?.rect;
				if (!rect) return;
				assert(rect.x >= 0 && rect.y >= 0 && rect.x + rect.w <= look.image.width + 0.01 && rect.y + rect.h <= look.image.height + 0.01, `rect out of bounds ${JSON.stringify(rect)}`);
			});
		});
		check("LIVE text annotations", () => {
			let found = false;
			walk(look.outline, (node) => {
				if (Array.isArray(node?.text) && node.text.length) found = true;
			});
			assert(found, "no text annotations");
		});
		check("LIVE window pairing", () => {
			assert(look.window?.metadata?.pairing, "missing window.metadata.pairing");
		});
		assert(Number.isFinite(target.pid), `could not resolve pid for ${windowLabel(target)}`);
		const centerX = Math.floor(look.image.width / 2);
		const centerY = Math.floor(look.image.height / 2);
		const hit = await call(socketPath, { id: "inv-hit-test", cmd: "hitTest", lookId: look.lookId, windowId: target.windowId, x: centerX, y: centerY }, 10000);
		const staleRef = await callEnvelope(socketPath, { id: "inv-act-stale-ref", cmd: "act", lookId: look.lookId, pid: target.pid, target: { ref: "bogus-ref-for-invariant" }, action: "press", params: {} }, 10000);
		const staleLook = await callEnvelope(socketPath, { id: "inv-act-stale-look", cmd: "act", lookId: "bogus-look-for-invariant", pid: target.pid, target: { x: centerX, y: centerY }, action: "moveMouse", params: {} }, 10000);
		check("LIVE hitTest and stale act errors", () => {
			assert(Number.isFinite(target.pid), `could not resolve pid for ${windowLabel(target)}`);
			assert(hit && typeof hit.role === "string", `hitTest did not return a node: ${JSON.stringify(hit)}`);
			assert(staleRef.ok === false && staleRef.error?.code === "stale_ref", `bogus ref did not return stale_ref: ${JSON.stringify(staleRef)}`);
			assert(staleLook.ok === false && staleLook.error?.code === "stale_look", `bogus look did not return stale_look: ${JSON.stringify(staleLook)}`);
		});
		check("LIVE projection stays inside the agent vocabulary", () => {
			const parsed = parseLookResponse(look).parsedOutline;
			assert(parsed, "parseLookResponse did not return parsed outline");
			const projection = project(parsed);
			assert(projection.nodes.length > 0, "projection produced no nodes");
			assert(projection.total === parsed.nodes.length, `projection total ${projection.total} != outline ${parsed.nodes.length}`);
			for (const node of projection.nodes) {
				assert(!/^ax/i.test(node.role), `projected role kept its AX prefix: ${node.role}`);
				for (const capability of node.caps) assert(CAPABILITIES.includes(capability), `projected capability outside the vocabulary: ${capability}`);
			}
			const text = renderObservation({ stateId: "live", root: { ref: "@r1", app: "live", title: windowLabel(target) }, nodes: projection.nodes, shown: projection.shown, total: projection.total });
			assert(!/\bAX[A-Z]/.test(text), `live view leaks raw accessibility names:\n${text}`);
			const focused = parsed.nodes.filter((node) => node.focused && node.canFocus);
			for (const node of focused) {
				const visible = projection.nodes.some((candidate) => candidate.ref === node.ref) || projection.nodes.some((candidate) => candidate.hidden);
				assert(visible, `focused ref ${node.ref} was neither rendered nor folded`);
			}
		});
		const fullOutline = parseLookResponse(look).parsedOutline;
		const truncated = fullOutline?.nodes.find((node) => node.truncated && node.wireRef);
		if (!fullOutline || !truncated) {
			console.log(`SKIP LIVE scoped graft (no truncated node in ${windowLabel(target)})`);
		} else {
			const beforeRefs = new Map(fullOutline.nodes.map((node) => [node.ref, node.wireRef]));
			const beforeMax = Math.max(...fullOutline.nodes.map((node) => Number(/^@e(\d+)$/.exec(node.ref)?.[1] ?? 0)));
			const state = { stateId: "full-state", capture: { width: look.image.width, height: look.image.height } };
			const scopedLook = await call(socketPath, { id: "inv-look-scope", cmd: "look", windowId: target.windowId, readText: "auto", scopeRef: truncated.wireRef, maxDimension: 1 }, 20000);
			check("LIVE scoped graft preserves full state", () => {
				const scopedOutline = parseLookResponse(scopedLook).parsedOutline;
				assert(scopedOutline, "scoped look did not parse");
				graftScopedOutline(fullOutline, truncated.ref, scopedOutline);
				for (const [ref, wireRef] of beforeRefs) {
					const node = nodeByRef(fullOutline, ref);
					assert(node, `pre-existing ref disappeared: ${ref}`);
					assert(node.wireRef === wireRef, `pre-existing ref changed elementRef: ${ref}`);
				}
				assert(state.stateId === "full-state" && state.capture.width === look.image.width && state.capture.height === look.image.height, "state/capture sentinel changed");
				const afterMax = Math.max(...fullOutline.nodes.map((node) => Number(/^@e(\d+)$/.exec(node.ref)?.[1] ?? 0)));
				assert(afterMax >= beforeMax, "ref counter moved backwards");
				for (const node of fullOutline.nodes) {
					const number = Number(/^@e(\d+)$/.exec(node.ref)?.[1] ?? 0);
					if (!beforeRefs.has(node.ref)) assert(number > beforeMax, `new ref did not continue numbering: ${node.ref}`);
				}
			});
		}
	} catch (error) {
		results.push(["LIVE", false]);
		process.exitCode = 1;
		console.error(`FAIL LIVE ${error.message}`);
	}
}

await liveChecks();
if (results.some(([, ok]) => !ok)) process.exit(1);
