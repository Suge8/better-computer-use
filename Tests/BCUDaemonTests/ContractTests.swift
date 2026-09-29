import BCUCore
@testable import BCUDaemon
@testable import BCUPlatform
import Foundation
import Testing

// The public output contract of every command, over recorded outlines: result shapes, the
// text views the CLI prints for them, and the errors. act-ui succeeds unless an action
// provably failed: an outcome no evidence could judge is reported as unverified, and an
// action that closes its own root is proof in itself and hands over the app's next root.
// Offscreen elements outside the view come and go as one summary line, not a line each. A
// window read from the screen hands over the screenshot taken for it.

private let fixtureApp = RunningApp(appName: "Fixture", pid: 4242, bundleId: "com.example.fixture", isFrontmost: true)
private let emptyApp = RunningApp(appName: "Empty", pid: 4343, bundleId: "com.example.empty", isFrontmost: false)
private let desktopApp = RunningApp(appName: "Desktop", pid: 4444, bundleId: "com.example.desktop", isFrontmost: false)
private let rowsApp = RunningApp(appName: "Rows", pid: 4545, bundleId: "com.example.rows", isFrontmost: false)
private let webApp = RunningApp(appName: "Web", pid: 4646, bundleId: "com.example.web", isFrontmost: false)
// An exact app name wins over the longer names that contain it.
private let twinApp = RunningApp(appName: "Twin", pid: 4747, bundleId: "com.example.twin", isFrontmost: false)
private let twinTestingApp = RunningApp(appName: "Twin for Testing", pid: 4848, bundleId: "com.example.twin.testing", isFrontmost: false)
private let editorApp = RunningApp(appName: "Editor", pid: 4949, bundleId: "com.example.editor", isFrontmost: false)
/// Says almost nothing through Accessibility, so the platform captures and reads it on its own.
private let drawnApp = RunningApp(appName: "Drawn", pid: 5050, bundleId: "com.example.drawn", isFrontmost: false)

/// Keys the scripted app answers with an outcome no evidence could judge, and with a proven no-op.
private let unjudgedKey = "F19"
private let noOpKey = "F18"
/// A key after which the scripted app grows, then drops, a batch of offscreen menu items.
private let noiseKey = "F17"
private let noiseItems = 30

private let fixtureWindow = root("w1", pid: 4242, app: "Fixture", bundleId: "com.example.fixture", title: "未命名2", windowId: 9001, frame: CGRect(x: 0, y: 0, width: 586, height: 488), zOrder: 1, focused: true, main: true)
private let menuBarRoot = root("menubar1", pid: 4242, app: "Fixture", bundleId: "com.example.fixture", kind: .menubar, title: "Fixture", role: "AXMenuBar", subrole: "", frame: CGRect(x: 0, y: 0, width: 2560, height: 30), zOrder: 900)
private let menuRoot = root("menu9", pid: 4242, app: "Fixture", bundleId: "com.example.fixture", kind: .menu, title: "文件", role: "AXMenu", subrole: "", frame: CGRect(x: 110, y: 31, width: 237, height: 425), focused: true)
private let sheetRoot = root("sheet1", pid: 4242, app: "Fixture", bundleId: "com.example.fixture", kind: .sheet, title: "警告", role: "AXSheet", subrole: "", windowId: 9101, frame: CGRect(x: 40, y: 40, width: 420, height: 160), focused: true)
private let sheetButtons = [("sheet-save", "仍要保存"), ("sheet-cancel", "取消")]

private func plainWindow(_ app: RunningApp) -> Root {
	root("w\(app.pid)", pid: app.pid, app: app.appName, bundleId: app.bundleId, title: "\(app.appName) window", windowId: UInt32(app.pid == webApp.pid ? 9003 : Int(app.pid)), frame: CGRect(x: 0, y: 0, width: 1200, height: 800), zOrder: 3, main: true)
}

/// The scripted world and the state its actions change.
private final class World: @unchecked Sendable {
	private let lock = NSLock()
	private var _sheetOpen = false
	private var _noiseParent: (role: String, subrole: String, identifier: String, rect: CGRect)?
	private var _noisePresent = false

	var sheetOpen: Bool {
		get { lock.withLock { _sheetOpen } }
		set { lock.withLock { _sheetOpen = newValue } }
	}

	var noiseParent: (role: String, subrole: String, identifier: String, rect: CGRect)? {
		get { lock.withLock { _noiseParent } }
		set { lock.withLock { _noiseParent = newValue } }
	}

	var noisePresent: Bool {
		get { lock.withLock { _noisePresent } }
		set { lock.withLock { _noisePresent = newValue } }
	}
}


private func contract() throws -> (Harness, World) {
	let textEdit = try fixture("textedit")
	let rows = try fixture("finder")
	let web = try fixture("chrome")
	let editorOutline = try fixture("editor")
	let world = World()
	var scene = FakeDesktop.Scene()
	scene.apps = [fixtureApp, emptyApp, desktopApp, rowsApp, webApp, twinApp, twinTestingApp, editorApp, drawnApp]
	scene.roots = [
		fixtureApp.pid: [fixtureWindow, menuBarRoot],
		emptyApp.pid: [],
		desktopApp.pid: [root("desktop", pid: desktopApp.pid, app: "Desktop", title: "", role: "AXScrollArea", subrole: "AXDesktop", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), zOrder: 99)],
		rowsApp.pid: [root("w2", pid: rowsApp.pid, app: "Rows", title: "MacBook Pro", windowId: 9002, frame: CGRect(x: 0, y: 0, width: 920, height: 556), zOrder: 2, main: true)],
		webApp.pid: [plainWindow(webApp)],
		twinApp.pid: [plainWindow(twinApp)],
		twinTestingApp.pid: [plainWindow(twinTestingApp)],
		editorApp.pid: [plainWindow(editorApp)],
		drawnApp.pid: [plainWindow(drawnApp)],
	]
	scene.read = { _ in "fixture text slice" }
	let harness = Harness(scene)
	let desktop = harness.desktop

	@Sendable func withNoise(_ look: LookNode) -> LookNode {
		let parent = world.noiseParent, present = world.noisePresent
		func visit(_ node: LookNode) {
			if present, let parent, node.role == parent.role, node.subrole == parent.subrole, node.identifier == parent.identifier, node.rect == parent.rect {
				node.children += (0..<noiseItems).map { BCUDaemonTests.node("noise-\($0)", role: "AXMenuItem", title: "菜单项 \($0)", canPress: true, offscreen: true) }
			}
			node.children.forEach(visit)
		}
		visit(look)
		return look
	}

	desktop.update { scene in
		scene.look = { request in
			let values = desktop.scene.values
			switch request.root {
			case Handle("sheet1"):
				guard world.sheetOpen else { throw BCUError(.windowStale, "Window 9101 is not available for capture") }
				let buttons = sheetButtons.map { node($0.0, role: "AXButton", title: $0.1, canPress: true) }
				return lookResult(node("sheet", role: "AXSheet", children: buttons), frame: sheetRoot.framePoints, windowId: 9101, kind: .sheet)
			case Handle("w5050"):
				let line = node(nil, role: LookNode.ocrRole, title: "发送", rect: CGRect(x: 300, y: 250, width: 60, height: 20))
				return lookResult(node("drawn", role: "AXWindow", title: "Drawn", rect: CGRect(x: 0, y: 0, width: 400, height: 300), children: [line]), frame: CGRect(x: 0, y: 0, width: 400, height: 300), windowId: 5050, image: true, readScreen: true)
			case Handle("w2"):
				return lookResult(node(rows.root, values: values), frame: CGRect(x: 0, y: 0, width: 920, height: 556), windowId: 9002, image: request.includeImage)
			case Handle("w4646"):
				return lookResult(node(web.root, values: values), frame: CGRect(x: 0, y: 0, width: 1200, height: 800), windowId: 9003, image: request.includeImage)
			case Handle("w4949"):
				return lookResult(node(editorOutline.root, values: values), frame: CGRect(x: 0, y: 0, width: 1200, height: 800), windowId: 4949, image: request.includeImage)
			case Handle("w1"):
				return lookResult(withNoise(node(textEdit.root, values: values)), frame: CGRect(x: 0, y: 0, width: 586, height: 488), windowId: 9001, image: request.includeImage)
			default:
				return lookResult(node("plain", role: "AXWindow", title: "window"), image: request.includeImage)
			}
		}
		scene.answer = { request in
			let target = handle(of: request.target)
			if let target, sheetButtons.contains(where: { Handle($0.0) == target }) {
				world.sheetOpen = false
				desktop.update { $0.roots[fixtureApp.pid] = [fixtureWindow, menuBarRoot] }
				return reported(.unknown, delta: [.root(.closed, sheetRoot)])
			}
			if request.action == .setText, let target, let name = target.base.base as? String {
				desktop.update { $0.values[name] = request.params.text }
			}
			let keys = request.action == .keypress ? request.params.keys : []
			if keys.contains(noiseKey), let target, let name = target.base.base as? String {
				let present = !world.noisePresent
				world.noisePresent = present
				desktop.update { $0.values[name] = present ? "noise on" : "noise off" }
				return reported(.worked, evidence: ActEvidence(source: .ax, field: .value))
			}
			if keys.contains(unjudgedKey) { return reported(.unknown) }
			if keys.contains(noOpKey) { return reported(.didnt, request.policy == .foreground ? .hid : .pid) }
			return reported(.worked, evidence: ActEvidence(source: .ax, field: .value, from: "0", to: "1"), delta: request.action == .press ? [.root(.appeared, menuRoot)] : [])
		}
		scene.wait = { request in
			let wanted = request.value ?? request.text
			return desktop.scene.values.values.contains { $0 == wanted } ? .found : .timedOut
		}
	}
	return (harness, world)
}

private extension Harness {
	func openSheet(_ world: World) async throws -> (sheet: RootInfo, view: ObserveResult, save: String, cancel: String) {
		world.sheetOpen = true
		desktop.update { $0.roots[fixtureApp.pid] = [fixtureWindow, menuBarRoot, sheetRoot] }
		let sheet = try #require(try await roots(#"{"app":"Fixture","kind":"sheet"}"#).first)
		let view = try await observe(#"{"root":"\#(sheet.ref)"}"#)
		func button(_ name: String) throws -> String { try #require(view.nodes.first { $0.name == name }?.ref) }
		return (sheet, view, try button("仍要保存"), try button("取消"))
	}

	func shotFiles() -> Set<String> {
		Set((try? FileManager.default.contentsOfDirectory(atPath: shots)) ?? [])
	}
}

private func encoded<T: Encodable>(_ value: T) throws -> String {
	try JSONCoding.string(value)
}

private func keys(_ value: JSONValue) -> [String] {
	guard case .object(let members) = value else { return [] }
	return members.map(\.key).sorted()
}

private func lines(_ text: String) -> [String] {
	text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

private func matches(_ text: String, _ pattern: String) -> Bool {
	text.range(of: pattern, options: .regularExpression) != nil
}

@Suite(.timeLimit(.minutes(1)))
struct ContractTests {
	@Test func queriesOverOneStateKeepTheirShapes() async throws {
		let (harness, _) = try contract()
		let observed = try await harness.json(#"{"command":"observe-ui","params":{"app":"Fixture"}}"#)
		#expect(keys(observed) == ["nodes", "root", "shown", "stateId", "total"])
		#expect(observed["total"] == .number(47))
		#expect(observed["nodes"]?.array?.first?["role"] == .string("window"))
		#expect(!matches(observed.serialized(), #""AX|_NS:"#), "observe-ui JSON leaks raw accessibility names")
		#expect(harness.shotFiles().isEmpty, "observe-ui wrote a screenshot without being asked")

		let header = lines(try await harness.text(#"{"command":"observe-ui","params":{"app":"Fixture"}}"#))[0]
		#expect(matches(header, #"^@r\d+ Fixture — 未命名2 · state [0-9a-z]{8} · 47 nodes, \d+ shown$"#), "observe-ui header drifted: \(header)")

		let stateId = try #require(observed["stateId"]?.string)
		let searched = try await harness.json(#"{"command":"search-ui","params":{"stateId":"\#(stateId)","role":"textarea"}}"#)
		#expect(keys(searched) == ["matches", "stateId", "total"])
		#expect(searched["stateId"] == .string(stateId))
		let editor = try #require(searched["matches"]?.array?.first)
		#expect(editor["role"] == .string("textarea"))
		#expect(editor["path"]?.array != nil)
		let editorRef = try #require(editor["ref"]?.string)

		guard case .searchUi(let byCapability) = try await harness.run(#"{"command":"search-ui","params":{"stateId":"\#(stateId)","action":"setText"}}"#) else { Issue.record(); return }
		#expect(byCapability.matches.contains { $0.node.ref == editorRef })
		#expect(byCapability.matches.allSatisfy { $0.node.caps.contains(.setText) })

		let expanded = try await harness.json(#"{"command":"expand-ui","params":{"stateId":"\#(stateId)","ref":"@e3"}}"#)
		#expect(keys(expanded) == ["nodes", "ref", "stateId"])
		#expect((expanded["nodes"]?.array?.count ?? 0) > 1)

		let inspected = try await harness.json(#"{"command":"inspect-ui","params":{"stateId":"\#(stateId)","ref":"\#(editorRef)"}}"#)
		#expect(keys(inspected) == ["node", "stateId"])
		#expect(inspected["node"]?["role"] == .string("AXTextArea"))

		let read = try await harness.json(#"{"command":"read-text","params":{"stateId":"\#(stateId)","ref":"\#(editorRef)"}}"#)
		#expect(keys(read) == ["limit", "offset", "ref", "stateId", "text", "total"])
		#expect(read["text"] == .string("fixture text slice"))
	}

	@Test func aVerifiedActionReportsItsEvidenceAndDiff() async throws {
		let (harness, _) = try contract()
		let state = try await harness.observe(#"{"app":"Fixture"}"#)
		let editorRef = try #require(state.nodes.first { $0.role == "textarea" }?.ref)
		let acted = try await harness.json(harness.actRequest(state.stateId, #"[{"action":"setText","ref":"\#(editorRef)","text":"typed"}]"#, #","expect":{"value":"typed","timeoutMs":1000}"#))
		#expect(keys(acted) == ["baseStateId", "changes", "delivery", "outcome", "stateId", "verification"])
		guard case .actUi(let result) = try CommandResult.decode(.actUi, from: acted) else { Issue.record(); return }
		#expect(result.baseStateId == state.stateId)
		#expect(result.verification.status == .verified)
		#expect(result.verification.evidence == ActEvidence(source: .ax, field: .value, from: "0", to: "1"))
		#expect(try encoded(result.changes) == #"[{"type":"updated","ref":"\#(editorRef)","fields":{"value":"typed"}}]"#)

		let actedState = try #require(result.stateId)
		guard case .waitFor(let waited) = try await harness.run(#"{"command":"wait-for","params":{"stateId":"\#(actedState)","text":"typed","timeoutMs":1000}}"#) else { Issue.record(); return }
		#expect(waited.found)
		#expect(matches(waited.stateId, "^[0-9a-z]{8}$"))
		#expect(waited.stateId != actedState)
		#expect(await expectCode(.actionTimeout) { _ = try await harness.run(#"{"command":"wait-for","params":{"stateId":"\#(actedState)","text":"__never__","timeoutMs":200}}"#) })
	}

	/// A root the action opened is the agent's next target, handed over with a usable @r.
	@Test func anOpenedRootIsHandedOverWithARef() async throws {
		let (harness, _) = try contract()
		let state = try await harness.observe(#"{"app":"Fixture"}"#)
		let editorRef = try #require(state.nodes.first { $0.role == "textarea" }?.ref)
		let opened = try await harness.act(state.stateId, #"[{"action":"press","ref":"\#(editorRef)"}]"#)
		let menu = try #require(opened.roots?.first)
		#expect(opened.roots?.count == 1)
		#expect(matches(menu.ref, #"^@r\d+$"#))
		#expect(menu.kind == .menu && menu.app == "Fixture" && menu.title == "文件")
		let text = try await harness.text(harness.actRequest(try #require(opened.stateId), #"[{"action":"press","ref":"\#(editorRef)"}]"#))
		#expect(matches(lines(text)[0], " · worked via ax · value 0→1$"), "act-ui does not show why it worked: \(lines(text)[0])")
		#expect(text.contains("+ root \(menu.ref) menu \"文件\""))
	}

	/// An unjudged action is not a failure; a step that did nothing stops the array and fails it.
	@Test func unjudgedStepsContinueAndNoOpsFail() async throws {
		let (harness, _) = try contract()
		let state = try await harness.observe(#"{"app":"Fixture"}"#)
		let editorRef = try #require(state.nodes.first { $0.role == "textarea" }?.ref)
		let unjudged = #"{"action":"keypress","ref":"\#(editorRef)","keys":["\#(unjudgedKey)"]}"#
		let text = lines(try await harness.text(harness.actRequest(state.stateId, "[\(unjudged)]")))
		#expect(matches(text[0], #"^state [0-9a-z]{8} ← [0-9a-z]{8} · unverified via ax$"#), "\(text[0])")
		#expect(text[1] == "(no element changes)")
		let next = String(text[0].split(separator: " ")[1])
		let unverified = try await harness.act(next, "[\(unjudged)]")
		#expect(unverified.outcome == .unknown)
		#expect(unverified.changes == [])

		let continued = try await harness.act(try #require(unverified.stateId), #"[\#(unjudged),{"action":"setText","ref":"\#(editorRef)","text":"after unknown"}]"#)
		#expect(harness.desktop.scene.acts.contains { $0.action == .setText })
		#expect(continued.outcome == .unknown)
		#expect(try encoded(continued.changes) == #"[{"type":"updated","ref":"\#(editorRef)","fields":{"value":"after unknown"}}]"#)

		harness.desktop.update { $0.acts = [] }
		#expect(await expectCode(.actionFailed) {
			_ = try await harness.act(try #require(continued.stateId), #"[{"action":"keypress","ref":"\#(editorRef)","keys":["\#(noOpKey)"]},{"action":"setText","ref":"\#(editorRef)","text":"never"}]"#)
		})
		#expect(!harness.desktop.scene.acts.contains { $0.action == .setText })

		// A satisfied postcondition is the evidence an unjudged action lacked.
		let fresh = try await harness.observe(#"{"app":"Fixture"}"#)
		let expected = try await harness.act(fresh.stateId, "[\(unjudged)]", #","expect":{"value":"after unknown","scope":"\#(editorRef)","timeoutMs":1000}"#)
		#expect(expected.outcome == .worked)
		#expect(expected.verification.status == .verified)
	}

	/// Offscreen elements outside the view are one summary line; a visible change keeps its own.
	@Test func offscreenNoiseIsSummarized() async throws {
		let (harness, world) = try contract()
		let view = try await harness.observe(#"{"app":"Fixture"}"#)
		let editorRef = try #require(view.nodes.first { $0.role == "textarea" }?.ref)
		let folded = try #require(view.nodes.first { $0.hidden != nil })
		guard case .inspectUi(let parent) = try await harness.run(#"{"command":"inspect-ui","params":{"stateId":"\#(view.stateId)","ref":"\#(folded.ref)"}}"#) else { Issue.record(); return }
		let rect = try #require(parent.node.rect)
		world.noiseParent = (parent.node.role, parent.node.subrole, parent.node.identifier, CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h))
		let noise = #"[{"action":"keypress","ref":"\#(editorRef)","keys":["\#(noiseKey)"]}]"#
		let grown = try await harness.text(harness.actRequest(view.stateId, noise))
		#expect(lines(grown).filter { matches($0, "^[+-] @e") }.isEmpty, "offscreen items were listed one by one:\n\(grown)")
		#expect(lines(grown).contains("~ \(editorRef) =\"noise on\""), "\(grown)")
		#expect(lines(grown).contains("… offscreen elements outside the view: \(noiseItems) added"), "\(grown)")
		let dropped = try await harness.act(String(lines(grown)[0].split(separator: " ")[1]), noise)
		#expect(try encoded(dropped.changes) == #"[{"type":"updated","ref":"\#(editorRef)","fields":{"value":"noise off"}}]"#)
		#expect(dropped.offscreen?.added == 0 && dropped.offscreen?.removed == noiseItems)
	}

	/// Pressing a button that closes its own sheet is proof the press landed; later steps are
	/// not sent to a root that no longer exists.
	@Test func closingTheRootHandsOverTheNextOne() async throws {
		let (harness, world) = try contract()
		var sheet = try await harness.openSheet(world)
		let closed = try await harness.act(sheet.view.stateId, #"[{"action":"press","ref":"\#(sheet.save)"}]"#)
		#expect(closed.outcome == .worked)
		#expect(closed.verification.evidence == ActEvidence(source: .root, field: .closed))
		#expect(try encoded(closed.closed?.root) == #"{"ref":"\#(sheet.sheet.ref)","kind":"sheet","app":"Fixture","title":"警告"}"#)
		#expect(closed.next?.kind == .window && closed.next?.title == "未命名2")
		#expect(closed.stateId.map { matches($0, "^[0-9a-z]{8}$") } == true)
		#expect((closed.nodes?.count ?? 0) > 0)
		let next = try await harness.observe(#"{"root":"\#(try #require(closed.next?.ref))"}"#)
		#expect(next.root.title == "未命名2")

		sheet = try await harness.openSheet(world)
		harness.desktop.update { $0.acts = [] }
		let text = lines(try await harness.text(harness.actRequest(sheet.view.stateId, #"[{"action":"press","ref":"\#(sheet.save)"},{"action":"press","ref":"\#(sheet.cancel)"}]"#)))
		#expect(harness.desktop.scene.acts.map { handle(of: $0.target) } == [Handle("sheet-save")])
		#expect(matches(text[0], #"^state [0-9a-z]{8} ← \#(sheet.view.stateId) · worked via ax · root closed$"#), "\(text[0])")
		#expect(text[1] == "- root \(sheet.sheet.ref) sheet \"警告\"")
		#expect(text.contains("skipped 1 later step: its root closed"))
		#expect(text.contains { matches($0, #"^next root @r\d+ window "未命名2"$"#) })
	}

	@Test func menuBarsAreListedOnlyWhenAskedFor() async throws {
		let (harness, _) = try contract()
		let menuBars = try await harness.roots(#"{"app":"Fixture","kind":"menubar"}"#)
		#expect(menuBars.count == 1)
		#expect(menuBars.first?.windowId == nil)
		#expect(try await harness.roots(#"{"kind":"menubar"}"#).count == 1)
		for params in [#"{}"#, #"{"app":"Fixture","kind":"window"}"#] {
			#expect(try await harness.roots(params).allSatisfy { $0.kind != .menubar }, "\(params) listed menu bars nobody asked for")
		}
		// Pairing is how the platform matched windows; it is not something an agent chooses by.
		#expect(!(try await harness.text(#"{"command":"find-roots","params":{"app":"Fixture"}}"#)).contains("pairing"))
		#expect(!(try await harness.json(#"{"command":"find-roots","params":{"app":"Fixture"}}"#)).serialized().contains("pairing"))
	}

	@Test func anExactAppNameWinsOverLongerOnes() async throws {
		let (harness, _) = try contract()
		#expect(try await harness.roots(#"{"app":"Twin"}"#).map(\.app) == ["Twin"])
		#expect(try await harness.roots(#"{"app":"Twi"}"#).map(\.app).sorted() == ["Twin", "Twin for Testing"])
	}

	@Test func searchByCapabilityFindsWhatTheViewPromises() async throws {
		let (harness, _) = try contract()
		let web = try await harness.observe(#"{"app":"Web"}"#)
		for capability in ["scroll", "menu"] {
			guard case .searchUi(let found) = try await harness.run(#"{"command":"search-ui","params":{"stateId":"\#(web.stateId)","action":"\#(capability)","limit":50}}"#) else { Issue.record(); return }
			#expect(found.matches.allSatisfy { $0.node.caps.contains(Capability(rawValue: capability)!) })
		}
		guard case .searchUi(let scroll) = try await harness.run(#"{"command":"search-ui","params":{"stateId":"\#(web.stateId)","action":"scroll"}}"#) else { Issue.record(); return }
		#expect(scroll.matches.map(\.node.name) == ["Scroll area"])

		// A line folded into a text input is still found; the input speaks for it.
		let editor = try await harness.observe(#"{"app":"Editor"}"#)
		guard case .searchUi(let line) = try await harness.run(#"{"command":"search-ui","params":{"stateId":"\#(editor.stateId)","text":"Fifth line"}}"#) else { Issue.record(); return }
		#expect(line.matches.map { "\($0.node.role) \($0.node.name)" } == ["textarea Editor"])
	}

	@Test func appsWithoutAControllableRootAreStaleWindows() async throws {
		let (harness, _) = try contract()
		do {
			_ = try await harness.observe(#"{"app":"Empty"}"#)
			Issue.record("an app without windows was observed")
		} catch let error as BCUError {
			#expect(error.code == .windowStale)
			#expect(error.message.hasPrefix("App 'Empty' is running but has no controllable window"))
		}
		#expect(await expectCode(.windowStale) { _ = try await harness.observe(#"{"app":"Desktop"}"#) })
	}

	@Test func aFoldedRowIsPressedThroughTheElementThatOwnsTheCapability() async throws {
		let (harness, _) = try contract()
		let rows = try await harness.observe(#"{"app":"Rows"}"#)
		let text = try await harness.text(#"{"command":"observe-ui","params":{"app":"Rows"}}"#)
		#expect(lines(text.trimmingCharacters(in: .whitespacesAndNewlines)).count == rows.nodes.count + 1)
		guard case .searchUi(let found) = try await harness.run(#"{"command":"search-ui","params":{"stateId":"\#(rows.stateId)","text":"下载"}}"#) else { Issue.record(); return }
		let row = try #require(found.matches.first?.node)
		#expect(row.role == "row")
		#expect(row.caps == [.open])
		#expect(row.owners?["open"] == "@e55")
		guard case .inspectUi(let inspected) = try await harness.run(#"{"command":"inspect-ui","params":{"stateId":"\#(rows.stateId)","ref":"\#(row.ref)"}}"#) else { Issue.record(); return }
		#expect(inspected.owners?["open"] == "@e55")
		_ = try await harness.act(rows.stateId, #"[{"action":"press","ref":"\#(row.ref)"}]"#)
		#expect(harness.desktop.scene.acts.last.flatMap { handle(of: $0.target) } == Handle("e1411"))
	}

	/// The screenshot taken to read a window is part of the result, in the JSON and the text view.
	@Test func aWindowReadFromTheScreenHandsOverItsScreenshot() async throws {
		let (harness, _) = try contract()
		let drawn = try await harness.observe(#"{"app":"Drawn"}"#)
		let image = try #require(drawn.image)
		#expect(image.mime == "image/jpeg" && image.width == 400 && image.height == 300)
		#expect((FileManager.default.contents(atPath: image.path)?.count ?? 0) > 0)
		let text = try await harness.text(#"{"command":"observe-ui","params":{"app":"Drawn"}}"#)
		#expect(matches(lines(text.trimmingCharacters(in: .whitespacesAndNewlines)).last!, #"^image \S+\.jpg \(400x300\)$"#))
		let acted = try await harness.act(drawn.stateId, #"[{"action":"keypress","keys":["\#(unjudgedKey)"],"x":330,"y":260}]"#)
		#expect(acted.image?.mime == "image/jpeg")

		let fused = try await harness.observe(#"{"app":"Fixture","mode":"fused"}"#)
		#expect(fused.image?.mime == "image/jpeg")
		#expect((FileManager.default.contents(atPath: try #require(fused.image?.path))?.count ?? 0) > 0)
	}

	@Test func refsFromAnotherStateOrNoneAreRefused() async throws {
		let (harness, _) = try contract()
		let state = try await harness.observe(#"{"app":"Fixture"}"#)
		#expect(await expectCode(.staleState) { _ = try await harness.run(#"{"command":"inspect-ui","params":{"stateId":"00000000","ref":"@e2"}}"#) })
		#expect(await expectCode(.elementNotFound) { _ = try await harness.run(#"{"command":"inspect-ui","params":{"stateId":"\#(state.stateId)","ref":"@e999"}}"#) })
		#expect(await expectCode(.elementNotFound) { _ = try await harness.run(#"{"command":"read-text","params":{"stateId":"\#(state.stateId)","ref":"@e999"}}"#) })
		#expect(await expectCode(.staleState) { _ = try await harness.act("00000000", #"[{"action":"press","ref":"@e2"}]"#) })
	}
}
