import BCUCore
@testable import BCUDaemon
@testable import BCUPlatform
import BCUTestSupport
import Foundation
import Testing

// act-ui across user interface: a root an action opens comes back already observed, and an
// action can name its element by role and name, in the root it looks in when its step runs.
// The scripted app is a notes window with a font popup, a New button that raises a sheet, and
// two Share buttons that nothing tells apart.

private let notesApp = RunningApp(appName: "Notes", pid: 7001, bundleId: "com.example.notes", isFrontmost: true)
private let notesWindow = root("nw", pid: 7001, app: "Notes", bundleId: "com.example.notes", title: "Notes", windowId: 7101, frame: CGRect(x: 0, y: 0, width: 600, height: 400), zOrder: 1, focused: true, main: true)
private let secondWindow = root("second", pid: 7001, app: "Notes", bundleId: "com.example.notes", title: "Second", windowId: 7103, frame: CGRect(x: 40, y: 40, width: 300, height: 200), zOrder: 2)
private let fontMenu = root("font-menu", pid: 7001, app: "Notes", bundleId: "com.example.notes", kind: .menu, title: "Font", role: "AXMenu", subrole: "", frame: CGRect(x: 20, y: 60, width: 160, height: 90), focused: true)
private let nameSheet = root("name-sheet", pid: 7001, app: "Notes", bundleId: "com.example.notes", kind: .sheet, title: "New note", role: "AXSheet", subrole: "", windowId: 7102, frame: CGRect(x: 60, y: 30, width: 400, height: 160), focused: true, modal: true)
private let fonts = ["Helvetica", "Times", "Courier"]

/// What the app shows, and the actions that change it.
private final class Notes: @unchecked Sendable {
	private let lock = NSLock()
	private var _extra: [Root] = []
	private var _font = "Helvetica"
	private var _name = ""
	private var _doc = ""
	private var _sheetLooks = 0
	/// The look of the sheet at which its Create button appears.
	var createAppearsAtLook = 1

	var extra: [Root] { lock.withLock { _extra } }
	var font: String { lock.withLock { _font } }
	var name: String { lock.withLock { _name } }
	var doc: String { lock.withLock { _doc } }
	var sheetLooks: Int { lock.withLock { _sheetLooks } }

	func open(_ roots: [Root]) { lock.withLock { _extra += roots.filter { root in !_extra.contains { $0.handle == root.handle } } } }
	func close(_ root: Root) { lock.withLock { _extra.removeAll { $0.handle == root.handle } } }
	func choose(_ font: String) { lock.withLock { _font = font } }
	func type(_ name: String) { lock.withLock { _name = name } }
	func create() { lock.withLock { _doc = "Created: \(_name)" } }
	func lookAtSheet() -> Int { lock.withLock { _sheetLooks += 1; return _sheetLooks } }
	func isOpen(_ root: Root) -> Bool { lock.withLock { _extra.contains { $0.handle == root.handle } } }
}

private func fontItems(handle: String) -> LookNode {
	node(handle, role: "AXMenu", children: fonts.map { node("item-\($0)", role: "AXMenuItem", title: $0, canPress: true) })
}

private func notesApp(_ notes: Notes) -> Harness {
	var scene = FakeDesktop.Scene()
	scene.apps = [notesApp]
	scene.roots = [7001: [notesWindow]]
	let harness = Harness(scene)
	let desktop = harness.desktop

	@Sendable func publish() { desktop.update { $0.roots[7001] = [notesWindow] + notes.extra } }
	@Sendable func closing(_ root: Root) -> ActionReport {
		notes.close(root)
		publish()
		return reported(.worked, delta: [.root(.closed, root)])
	}
	@Sendable func opening(_ roots: [Root]) -> ActionReport {
		notes.open(roots)
		publish()
		return reported(.worked, delta: roots.map { .root(.appeared, $0) })
	}

	desktop.update { scene in
		scene.look = { request in
			switch request.root {
			case Handle("nw"):
				// An open popup menu hangs under the popup in the window's own tree.
				let menu = notes.isOpen(fontMenu) ? [fontItems(handle: "font-menu")] : []
				let children = [
					node("popup", role: "AXPopUpButton", title: "Font", value: notes.font, canPress: true, children: menu),
					node("new", role: "AXButton", title: "New", canPress: true),
					node("both", role: "AXButton", title: "Both", canPress: true),
					node("another", role: "AXButton", title: "Another", canPress: true),
					node("share1", role: "AXButton", title: "Share", canPress: true),
					node("share2", role: "AXButton", title: "Share", canPress: true),
					node("doc", role: "AXStaticText", value: notes.doc),
				]
				return lookResult(node("nw-el", role: "AXWindow", title: "Notes", children: children), frame: notesWindow.framePoints, windowId: 7101)
			case Handle("font-menu"):
				guard notes.isOpen(fontMenu) else { throw BCUError(.windowStale, "The menu is gone") }
				return lookResult(fontItems(handle: "font-menu-el"), frame: fontMenu.framePoints, kind: .menu)
			case Handle("name-sheet"):
				guard notes.isOpen(nameSheet) else { throw BCUError(.windowStale, "The sheet is gone") }
				var children = [node("name", role: "AXTextField", title: "Name", value: notes.name, canSetValue: true), node("cancel", role: "AXButton", title: "Cancel", canPress: true)]
				if notes.lookAtSheet() >= notes.createAppearsAtLook { children.append(node("create", role: "AXButton", title: "Create", canPress: true)) }
				return lookResult(node("sheet-el", role: "AXSheet", children: children), frame: nameSheet.framePoints, windowId: 7102, kind: .sheet)
			default:
				return lookResult(node("other", role: "AXWindow", title: "Second"), frame: secondWindow.framePoints, windowId: 7103)
			}
		}
		scene.answer = { request in
			guard let target = handle(of: request.target) else { return reported(.worked) }
			switch target {
			case Handle("popup"): return opening([fontMenu])
			case Handle("new"): return opening([nameSheet, secondWindow])
			case Handle("both"): return opening([fontMenu, nameSheet])
			case Handle("another"): return opening([secondWindow])
			case Handle("name"):
				notes.type(request.params.text)
				return reported(.worked, evidence: ActEvidence(source: .ax, field: .value))
			case Handle("create"):
				notes.create()
				return closing(nameSheet)
			case Handle("cancel"): return closing(nameSheet)
			default:
				if fonts.contains(where: { Handle("item-\($0)") == target }) {
					notes.choose(String(String(describing: target.base.base).dropFirst("item-".count)))
					return closing(fontMenu)
				}
				return reported(.unknown)
			}
		}
		scene.wait = { request in
			guard let text = request.text else { return .found }
			return notes.doc.contains(text) || fonts.contains(text) && notes.isOpen(fontMenu) ? .found : .timedOut
		}
	}
	return harness
}

private func ref(_ nodes: [ProjectedNode], _ name: String) throws -> String {
	try #require(nodes.first { $0.name == name }?.ref)
}

private func delivered(_ harness: Harness) -> [Handle?] {
	harness.desktop.scene.acts.map { handle(of: $0.target) }
}

@Suite(.timeLimit(.minutes(1)), .temporaryRoot)
struct BatchTests {
	/// Choosing a dropdown option takes two commands: press the popup, then press the option in
	/// the view that comes back with it.
	@Test func aMenuOpenedByAPressComesBackObserved() async throws {
		let notes = Notes()
		let harness = notesApp(notes)
		let window = try await harness.observe(#"{"app":"Notes"}"#)
		let pressed = try await harness.act(window.stateId, #"[{"action":"press","ref":"\#(try ref(window.nodes, "Font"))"}]"#)
		let opened = try #require(pressed.opened)
		#expect(pressed.roots?.map(\.ref) == [opened.root.ref])
		#expect(opened.root.kind == .menu && opened.root.title == "Font")
		#expect(opened.nodes.compactMap { $0.role == "menuitem" ? $0.name : nil } == fonts)
		#expect(opened.shown == opened.nodes.count && opened.total == opened.nodes.count)
		#expect(pressed.changes == [], "the menu is reported once, as opened, not again as changes of the window")

		// The view is what observe-ui would have shown of that root.
		let observed = try await harness.observe(#"{"root":"\#(opened.root.ref)"}"#)
		#expect(observed.nodes == opened.nodes)

		// Both states are live until one of them acts; acting from the menu's stales the other.
		let picked = try await harness.act(opened.stateId, #"[{"action":"press","ref":"\#(try ref(opened.nodes, "Times"))"}]"#)
		#expect(delivered(harness) == [Handle("popup"), Handle("item-Times")])
		#expect(picked.closed?.root.ref == opened.root.ref)
		#expect(picked.next?.kind == .window)
		#expect(await expectCode(.staleState) { _ = try await harness.act(try #require(pressed.stateId), #"[{"action":"press","ref":"@e1"}]"#) })
	}

	/// Windows are left to observe-ui; of several transient roots the most prominent one is
	/// attached, and all of them are still listed.
	@Test func onlyOneTransientRootIsAttached() async throws {
		let harness = notesApp(Notes())
		let window = try await harness.observe(#"{"app":"Notes"}"#)
		let both = try await harness.act(window.stateId, #"[{"action":"press","ref":"\#(try ref(window.nodes, "Both"))"}]"#)
		#expect(both.roots?.count == 2)
		#expect(both.opened?.root.kind == .sheet, "the modal sheet outranks the menu")

		let again = try await harness.observe(#"{"root":"@r1"}"#)
		let another = try await harness.act(again.stateId, #"[{"action":"press","ref":"\#(try ref(again.nodes, "Another"))"}]"#)
		#expect(another.roots?.map(\.kind) == [.window])
		#expect(another.opened == nil, "a new window is observed on request, not attached")
	}

	/// Open a dialog, fill it in and confirm it in one array: the dialog does not exist when the
	/// array is written, so its steps find their elements when they run.
	@Test func aBatchCrossesIntoTheRootItOpens() async throws {
		let notes = Notes()
		let harness = notesApp(notes)
		let window = try await harness.observe(#"{"app":"Notes"}"#)
		let steps = """
		[{"action":"press","find":{"role":"button","name":"New"}},
		 {"action":"setText","text":"Report","find":{"role":"textfield","name":"Name","root":"opened"}},
		 {"action":"press","find":{"role":"button","name":"Create","root":"opened"},"expect":{"text":"Created: Report","root":"state"}}]
		"""
		let result = try await harness.act(window.stateId, steps)
		#expect(delivered(harness) == [Handle("new"), Handle("name"), Handle("create")])
		#expect(notes.doc == "Created: Report")
		#expect(result.closed?.root.kind == .sheet, "the confirm button closed the sheet")
		#expect(result.next == nil && result.stateId != nil, "the state's own root is still there to observe")
		#expect(result.verification.status == .verified)
		#expect(result.opened == nil)
		#expect(harness.desktop.scene.waits.last?.root == Handle("nw"), "the step's condition was checked in the root it named")
	}

	@Test func aFoundElementIsAwaitedUntilItAppears() async throws {
		let notes = Notes()
		notes.createAppearsAtLook = 4
		let harness = notesApp(notes)
		let window = try await harness.observe(#"{"app":"Notes"}"#)
		let steps = #"[{"action":"press","find":{"name":"New"}},{"action":"press","find":{"name":"Create","root":"opened","timeoutMs":5000}}]"#
		_ = try await harness.act(window.stateId, steps)
		#expect(delivered(harness).last == Handle("create"))
		#expect(notes.sheetLooks >= 4)
	}

	@Test func theRootTheAppWouldPickIsALookupRoot() async throws {
		let harness = notesApp(Notes())
		let window = try await harness.observe(#"{"app":"Notes"}"#)
		let result = try await harness.act(window.stateId, #"[{"action":"press","ref":"\#(try ref(window.nodes, "New"))"},{"action":"press","find":{"name":"Cancel","root":"app"}}]"#)
		#expect(delivered(harness) == [Handle("new"), Handle("cancel")])
		#expect(result.closed?.root.kind == .sheet)
	}

	/// Twins are a failure with their descriptions, found before anything is delivered, so the
	/// state is still good for another try.
	@Test func anAmbiguousFirstStepRefusesWithoutSpendingTheState() async throws {
		let harness = notesApp(Notes())
		let window = try await harness.observe(#"{"app":"Notes"}"#)
		do {
			_ = try await harness.act(window.stateId, #"[{"action":"press","find":{"role":"button","name":"Share"}}]"#)
			Issue.record("an ambiguous locator was acted on")
		} catch let error as BCUError {
			#expect(error.code == .elementNotFound)
			#expect(error.message.contains("matches 2 elements") && error.message.contains("nth 1: button \"Share\""), "\(error.message)")
		}
		#expect(harness.desktop.scene.acts.isEmpty)
		_ = try await harness.act(window.stateId, #"[{"action":"press","find":{"role":"button","name":"Share","nth":1}}]"#)
		#expect(delivered(harness) == [Handle("share2")])
	}

	/// A step that fails after others were delivered says so, and the delivered ones are not
	/// taken back: the state they came from is stale.
	@Test func aLaterStepThatCannotBeFoundStopsTheArray() async throws {
		let harness = notesApp(Notes())
		let window = try await harness.observe(#"{"app":"Notes"}"#)
		let steps = #"[{"action":"press","ref":"\#(try ref(window.nodes, "New"))"},{"action":"press","find":{"name":"Nope","root":"opened","timeoutMs":0}}]"#
		do {
			_ = try await harness.act(window.stateId, steps)
			Issue.record("a missing element was acted on")
		} catch let error as BCUError {
			#expect(error.code == .elementNotFound)
			#expect(error.message.hasPrefix("Step 2 of 2:") && error.recovery.contains("Step 1 was already delivered"), "\(error.message) / \(error.recovery)")
		}
		#expect(delivered(harness) == [Handle("new")])
		#expect(await expectCode(.staleState) { _ = try await harness.act(window.stateId, #"[{"action":"press","ref":"@e1"}]"#) })
	}

	@Test func aStepsOwnPostconditionGatesTheNextStep() async throws {
		let harness = notesApp(Notes())
		let window = try await harness.observe(#"{"app":"Notes"}"#)
		let popup = try ref(window.nodes, "Font"), another = try ref(window.nodes, "Another")
		#expect(await expectCode(.actionFailed) {
			_ = try await harness.act(window.stateId, #"[{"action":"press","ref":"\#(popup)","expect":{"text":"__never__","timeoutMs":100}},{"action":"press","ref":"\#(another)"}]"#)
		})
		#expect(delivered(harness) == [Handle("popup")], "the step after a failed postcondition was not delivered")

		let fresh = try await harness.observe(#"{"app":"Notes"}"#)
		let held = try await harness.act(fresh.stateId, #"[{"action":"press","ref":"\#(try ref(fresh.nodes, "Font"))","expect":{"text":"Times","root":"opened","timeoutMs":1000}}]"#)
		#expect(held.verification.status == .verified && held.outcome == .worked)
		#expect(harness.desktop.scene.waits.last?.root == Handle("font-menu"))
	}
}
