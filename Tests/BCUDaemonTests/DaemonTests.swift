import BCUCore
@testable import BCUDaemon
@testable import BCUPlatform
import Foundation
import Testing

// The resident commands over a fake editor app. Its window shows a button, a text field an
// action can change, and a group the platform cut short. A fresh outline numbers its refs
// breadth first: @e1 the window, @e2 the OK button, @e3 the text field, @e4 the group.

private func editorWindow(title: String = "Doc", handle: String = "win", windowId: UInt32 = 11, focused: Bool = true) -> Root {
	root(handle, pid: 101, app: "TextEdit", title: title, windowId: windowId, frame: CGRect(x: 10, y: 20, width: 800, height: 600), focused: focused, main: focused)
}

private func editorSheet() -> Root {
	root("sheet", pid: 101, app: "TextEdit", kind: .sheet, title: "Save", role: "AXSheet", subrole: "", frame: CGRect(x: 10, y: 40, width: 400, height: 200), focused: true, modal: true)
}

private func editorMenuBar() -> Root {
	root("bar", pid: 101, app: "TextEdit", kind: .menubar, title: "TextEdit", role: "AXMenuBar", subrole: "", frame: CGRect(x: 0, y: 0, width: 1440, height: 24), zOrder: Int.max)
}

private func editor() -> Harness {
	var scene = FakeDesktop.Scene()
	scene.apps = [RunningApp(appName: "TextEdit", pid: 101, bundleId: "com.apple.TextEdit", isFrontmost: true)]
	scene.roots = [101: [editorWindow(), editorMenuBar()]]
	scene.values = ["field": "draft"]
	let harness = Harness(scene)
	let desktop = harness.desktop
	desktop.update { scene in
		scene.read = { handle in handle == Handle("field") ? desktop.scene.values["field"] ?? "" : "" }
		scene.look = { request in
			let scene = desktop.scene
			guard scene.roots.values.joined().contains(where: { $0.handle == request.root }) else {
				throw BCUError(.windowStale, "Root reference is stale. Call find-roots again.")
			}
			if request.scope == Handle("group") {
				return lookResult(node("group", role: "AXGroup", children: [node("inner", role: "AXButton", title: "Inner", canPress: true)]))
			}
			var children = [
				node("ok", role: "AXButton", title: "OK", canPress: true, rect: CGRect(x: 10, y: 10, width: 60, height: 20)),
				node("field", role: "AXTextField", value: scene.values["field"] ?? "", canSetValue: true, rect: CGRect(x: 10, y: 40, width: 200, height: 20)),
				node("group", role: "AXGroup", title: "More", truncated: true),
			]
			if request.readText == .always { children.append(node(nil, role: LookNode.ocrRole, title: "Hello from the screen")) }
			return lookResult(node("win", role: "AXWindow", title: "Doc", rect: CGRect(x: 0, y: 0, width: 800, height: 600), children: children), windowId: 11, image: request.includeImage || request.readText == .always, readText: request.readText, readScreen: request.readText == .always)
		}
	}
	return harness
}

private extension Harness {
	func observe() async throws -> ObserveResult {
		_ = try await roots(#"{"app":"TextEdit"}"#)
		return try await observe(#"{"root":"@r1"}"#)
	}
}

@Suite(.timeLimit(.minutes(1)))
struct DiscoveryTests {
	@Test func aRootKeepsItsRefWhenItsTitleChanges() async throws {
		let harness = editor()
		guard case .findRoots(let first) = try await harness.run(#"{"command":"find-roots","params":{"app":"TextEdit"}}"#) else { Issue.record(); return }
		let window = try #require(first.roots.first { $0.kind == .window })
		harness.desktop.update { $0.roots[101] = [editorWindow(title: "Renamed"), editorWindow(title: "Second", handle: "win2", windowId: 12, focused: false)] }
		guard case .findRoots(let second) = try await harness.run(#"{"command":"find-roots","params":{"app":"TextEdit"}}"#) else { Issue.record(); return }
		#expect(second.roots.first { $0.title == "Renamed" }?.ref == window.ref)
		#expect(second.roots.first { $0.title == "Second" }.map { $0.ref != window.ref } == true)
		#expect(second.roots.first?.title == "Renamed", "the focused root comes first")
	}

	@Test func anUndirectedListingLeavesOutMenuBars() async throws {
		let harness = editor()
		guard case .findRoots(let broad) = try await harness.run(#"{"command":"find-roots","params":{}}"#) else { Issue.record(); return }
		#expect(broad.roots.map(\.kind) == [.window])
		guard case .findRoots(let named) = try await harness.run(#"{"command":"find-roots","params":{"app":"TextEdit"}}"#) else { Issue.record(); return }
		#expect(named.roots.map(\.kind).contains(.menubar))
	}

	@Test func observingAClosedRootIsAStaleWindow() async throws {
		let harness = editor()
		_ = try await harness.run(#"{"command":"find-roots","params":{"app":"TextEdit"}}"#)
		harness.desktop.update { $0.roots[101] = [editorMenuBar()] }
		#expect(await expectCode(.windowStale) { _ = try await harness.run(#"{"command":"observe-ui","params":{"root":"@r1"}}"#) })
	}

	/// A mistyped --root must never pick a window by a substring of its name; --app and
	/// --window-title are the named selectors.
	@Test func aRootThatIsNeitherARefNorAWindowIdIsRefused() async throws {
		let harness = editor()
		#expect(await expectCode(.invalidArguments) { _ = try await harness.run(#"{"command":"observe-ui","params":{"root":"Doc"}}"#) })
		#expect(await expectCode(.invalidArguments) { _ = try await harness.run(#"{"command":"observe-ui","params":{"root":"TextEdit"}}"#) })
	}

	@Test func missingPermissionsRefuseCommandsButNotDoctor() async throws {
		let harness = editor()
		harness.desktop.update { $0.permissions = false }
		#expect(await expectCode(.permissionMissing) { _ = try await harness.run(#"{"command":"find-roots","params":{}}"#) })
		let doctor = try await harness.plain(.doctor)
		#expect(doctor["permissions"]?["accessibility"] == .bool(false))
		#expect(doctor["permissions"]?["screenRecording"] == .bool(false))
	}

	@Test func setupRegistersThePermissions() async throws {
		let harness = editor()
		let setup = try await harness.plain(.setup)
		#expect(setup["accessibility"] == .bool(true))
		#expect(setup["screenRecording"] == .bool(true))
	}
}

@Suite(.timeLimit(.minutes(1)))
struct ObservationTests {
	@Test func observingARootSavesAStateWithItsView() async throws {
		let harness = editor()
		let result = try await harness.observe()
		#expect(result.root.ref == "@r1")
		#expect(result.root.app == "TextEdit")
		#expect(result.nodes.contains { $0.name == "OK" && $0.caps.contains(.press) })
		guard case .inspectUi(let inspected) = try await harness.run(#"{"command":"inspect-ui","params":{"stateId":"\#(result.stateId)","ref":"@e2"}}"#) else { Issue.record(); return }
		#expect(inspected.node.title == "OK")
	}

	@Test func anImageIsWrittenAsAPrivateArtifact() async throws {
		let harness = editor()
		_ = try await harness.roots(#"{"app":"TextEdit"}"#)
		let result = try await harness.observe(#"{"root":"@r1","image":"always"}"#)
		let image = try #require(result.image)
		#expect(image.path.hasPrefix(harness.shots))
		#expect(FileManager.default.contents(atPath: image.path) == Data([0xFF, 0xD8, 0xFF, 0xD9]))
		#expect(harness.desktop.scene.looks.last?.includeImage == true)
	}

	@Test func readTextReadsTheElementBehindTheRef() async throws {
		let harness = editor()
		let state = try await harness.observe()
		guard case .readText(let read) = try await harness.run(#"{"command":"read-text","params":{"stateId":"\#(state.stateId)","ref":"@e3","offset":1,"limit":3}}"#) else { Issue.record(); return }
		#expect(read.text == "raf")
		#expect(read.total == 5)
		#expect(harness.desktop.scene.reads == [Handle("field")])
	}

	@Test func expandingACutShortNodeKeepsTheGraftInTheState() async throws {
		let harness = editor()
		let state = try await harness.observe()
		guard case .expandUi(let expanded) = try await harness.run(#"{"command":"expand-ui","params":{"stateId":"\#(state.stateId)","ref":"@e4"}}"#) else { Issue.record(); return }
		#expect(harness.desktop.scene.looks.last?.scope == Handle("group"))
		let inner = try #require(expanded.nodes.first { $0.name == "Inner" })
		guard case .inspectUi(let inspected) = try await harness.run(#"{"command":"inspect-ui","params":{"stateId":"\#(state.stateId)","ref":"\#(inner.ref)"}}"#) else { Issue.record(); return }
		#expect(inspected.node.title == "Inner")
	}

	@Test func aSearchWithNothingToActOnReadsTheScreenOnce() async throws {
		let harness = editor()
		let state = try await harness.observe()
		guard case .searchUi(let found) = try await harness.run(#"{"command":"search-ui","params":{"stateId":"\#(state.stateId)","text":"Hello"}}"#) else { Issue.record(); return }
		#expect(found.stateId != state.stateId)
		#expect(found.matches.contains { $0.node.role == "ocr" })
		#expect(harness.desktop.scene.looks.last?.readText == .always)
	}

	@Test func waitingReturnsTheSuccessorStateOrTimesOut() async throws {
		let harness = editor()
		let state = try await harness.observe()
		harness.desktop.update { $0.values["field"] = "done" }
		guard case .waitFor(let waited) = try await harness.run(#"{"command":"wait-for","params":{"stateId":"\#(state.stateId)","text":"done"}}"#) else { Issue.record(); return }
		#expect(waited.found)
		#expect(waited.stateId != state.stateId)
		#expect(waited.changes?.isEmpty == false)
		#expect(harness.desktop.scene.waits.last?.root == Handle("win"))
		harness.desktop.update { $0.wait = { _ in .timedOut } }
		#expect(await expectCode(.actionTimeout) { _ = try await harness.run(#"{"command":"wait-for","params":{"stateId":"\#(waited.stateId)","text":"never"}}"#) })
	}
}

@Suite(.timeLimit(.minutes(1)))
struct ActionTests {
	@Test func aPressIsDeliveredToTheObservedElementAndStalesItsBase() async throws {
		let harness = editor()
		let state = try await harness.observe()
		harness.desktop.update { scene in
			scene.answer = { _ in
				harness.desktop.update { $0.values["field"] = "pressed" }
				return reported(.worked)
			}
		}
		let result = try await harness.act(state.stateId, #"[{"action":"press","ref":"@e2"}]"#)
		let delivered = try #require(harness.desktop.scene.acts.first)
		#expect(handle(of: delivered.target) == Handle("ok"))
		#expect(delivered.policy == .background)
		#expect(result.baseStateId == state.stateId)
		#expect(result.outcome == .worked)
		#expect(result.changes?.isEmpty == false)
		#expect(await expectCode(.staleState) { _ = try await harness.act(state.stateId, #"[{"action":"press","ref":"@e2"}]"#) })
		let successor = try #require(result.stateId)
		_ = try await harness.act(successor, #"[{"action":"press","ref":"@e2"}]"#)
	}

	@Test func aRejectedActionLeavesTheStateCurrent() async throws {
		let harness = editor()
		let state = try await harness.observe()
		#expect(await expectCode(.elementNotFound) { _ = try await harness.act(state.stateId, #"[{"action":"press","ref":"@e99"}]"#) })
		#expect(harness.desktop.scene.acts.isEmpty)
		_ = try await harness.act(state.stateId, #"[{"action":"press","ref":"@e2"}]"#)
	}

	@Test func aBackgroundNoOpIsRetriedInTheForeground() async throws {
		let harness = editor()
		let state = try await harness.observe()
		harness.desktop.update { $0.answer = { $0.policy == .foreground ? reported(.worked, .hid) : reported(.didnt) } }
		let result = try await harness.act(state.stateId, #"[{"action":"press","ref":"@e2"}]"#)
		#expect(harness.desktop.scene.acts.map(\.policy) == [.background, .foreground])
		#expect(harness.desktop.scene.acts.last?.params.pidDelivery == false)
		#expect(result.outcome == .worked)
		#expect(result.delivery == "hid")
	}

	@Test func aRefusalThatNeedsTheForegroundIsRetriedThere() async throws {
		let harness = editor()
		let state = try await harness.observe()
		harness.desktop.update { $0.answer = { request in
			guard request.policy == .foreground else { throw ForegroundRequired(message: "needs the pointer") }
			return reported(.worked, .hid)
		} }
		_ = try await harness.act(state.stateId, #"[{"action":"press","ref":"@e2"}]"#)
		#expect(harness.desktop.scene.acts.map(\.policy) == [.background, .foreground])
	}

	@Test func headlessNeverLeavesTheBackgroundAndFailsAProvenNoOp() async throws {
		let harness = editor()
		let state = try await harness.observe()
		harness.desktop.update { $0.answer = { _ in reported(.didnt) } }
		#expect(await expectCode(.actionFailed) { _ = try await harness.act(state.stateId, #"[{"action":"press","ref":"@e2"}]"#, #","headless":true"#) })
		#expect(harness.desktop.scene.batches.first?.map(\.policy) == [.axOnly])
		#expect(harness.desktop.scene.acts.isEmpty)
	}

	@Test func foregroundStartsTheLadderInTheForeground() async throws {
		let harness = editor()
		let state = try await harness.observe()
		harness.desktop.update { $0.answer = { _ in reported(.unknown, .hid) } }
		let result = try await harness.act(state.stateId, #"[{"action":"press","ref":"@e2"}]"#, #","foreground":true"#)
		#expect(harness.desktop.scene.acts.map(\.policy) == [.foreground])
		#expect(harness.desktop.scene.acts.first?.params.pidDelivery == false)
		#expect(result.delivery == "hid")
	}

	@Test func foregroundContradictsHeadless() async throws {
		let harness = editor()
		let state = try await harness.observe()
		#expect(await expectCode(.invalidArguments) { _ = try await harness.act(state.stateId, #"[{"action":"press","ref":"@e2"}]"#, #","foreground":true,"headless":true"#) })
		#expect(harness.desktop.scene.acts.isEmpty && harness.desktop.scene.batches.isEmpty)
	}

	@Test func anActionThatClosesItsRootReportsTheRootTheAppShowsNext() async throws {
		let harness = editor()
		harness.desktop.update { $0.roots[101] = [editorSheet(), editorWindow(focused: false)] }
		let state = try await harness.observe(#"{"app":"TextEdit"}"#)
		#expect(state.root.title == "Save")
		harness.desktop.update { scene in
			scene.answer = { _ in
				harness.desktop.update { $0.roots[101] = [editorWindow()] }
				return reported(.worked, delta: [.root(.closed, editorSheet())])
			}
		}
		let result = try await harness.act(state.stateId, #"[{"action":"press","ref":"@e2"},{"action":"press","ref":"@e2"}]"#)
		#expect(result.closed?.root.title == "Save")
		#expect(result.closed?.skipped == 1)
		#expect(result.next?.title == "Doc")
		#expect(result.verification.evidence == ActEvidence(source: .root, field: .closed))
		#expect(result.stateId != nil)
		#expect(harness.desktop.scene.acts.count == 1)
	}

	@Test func aPostconditionDecidesTheTransaction() async throws {
		let harness = editor()
		let state = try await harness.observe()
		harness.desktop.update { $0.wait = { _ in .timedOut } }
		#expect(await expectCode(.actionFailed) { _ = try await harness.act(state.stateId, #"[{"action":"press","ref":"@e2"}]"#, #","expect":{"text":"Saved"}"#) })
		harness.desktop.update { $0.wait = { _ in .found } }
		let fresh = try await harness.observe()
		let result = try await harness.act(fresh.stateId, #"[{"action":"press","ref":"@e2"}]"#, #","expect":{"text":"Saved"}"#)
		#expect(result.verification.status == .verified)
		#expect(harness.desktop.scene.waits.last?.text == "Saved")
	}
}
