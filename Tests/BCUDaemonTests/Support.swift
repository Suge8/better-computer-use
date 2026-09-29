import BCUCore
@testable import BCUDaemon
@testable import BCUPlatform
import BCURuntime
import Foundation

/// A scripted desktop. A scene lists the apps and their roots, answers looks, actions, waits
/// and reads, and records every request the daemon made.
final class FakeDesktop: Desktop, @unchecked Sendable {
	struct Scene {
		var apps: [RunningApp] = []
		var roots: [Int32: [Root]] = [:]
		var permissions = true
		/// Element values actions changed, by handle name.
		var values: [String: String] = [:]
		var looks: [LookRequest] = []
		var acts: [ActRequest] = []
		var batches: [[ActRequest]] = []
		var waits: [WaitForRequest] = []
		var reads: [Handle] = []
		var look: @Sendable (LookRequest) throws -> sending LookResult = { _ in throw BCUError(.windowStale, "Root reference is stale. Call find-roots again.") }
		/// Answers each delivered action; the default presses fine and changes nothing.
		var answer: @Sendable (ActRequest) throws -> ActionReport = { _ in ActionReport(outcome: .worked, performed: ActPerformed(delivery: .ax)) }
		var wait: @Sendable (WaitForRequest) -> WaitOutcome = { _ in .found }
		var read: @Sendable (Handle) -> String = { _ in "" }
	}

	private let lock = NSLock()
	private var state: Scene

	init(_ scene: Scene = Scene()) {
		state = scene
	}

	func update<T>(_ body: (inout Scene) throws -> T) rethrows -> T {
		lock.lock()
		defer { lock.unlock() }
		return try body(&state)
	}

	var scene: Scene { update { $0 } }

	func listApps() -> [RunningApp] { scene.apps }

	func listRoots(pid: Int32?, title: String?) -> [Root] {
		let roots = scene.roots
		if let pid { return roots[pid] ?? [] }
		return roots.keys.sorted().flatMap { roots[$0]! }.filter { title == nil || $0.title.lowercased().contains(title!.lowercased()) }
	}

	func frontmost() throws -> Frontmost {
		let scene = scene
		let app = scene.apps.first { $0.isFrontmost } ?? scene.apps[0]
		return Frontmost(appName: app.appName, pid: app.pid, bundleId: app.bundleId, window: scene.roots[app.pid]?.first)
	}

	func look(_ request: LookRequest) throws -> sending LookResult {
		let look = update { scene in
			scene.looks.append(request)
			return scene.look
		}
		return try look(request)
	}

	func act(_ request: ActRequest) throws -> ActionReport {
		let answer = update { scene in
			scene.acts.append(request)
			return scene.answer
		}
		return try answer(request)
	}

	func actBatch(_ requests: [ActRequest]) throws -> BatchReport {
		let answer = update { scene in
			scene.batches.append(requests)
			return scene.answer
		}
		var steps: [ActStep] = []
		var rootDelta: [RootChange] = []
		for request in requests {
			do {
				let step = try answer(request)
				steps.append(.completed(step))
				rootDelta += step.rootDelta
				if step.outcome == .didnt { break }
			} catch let error as BCUError {
				steps.append(.failed(message: error.message))
				break
			}
		}
		let outcomes = steps.map(\.outcome)
		let outcome: ActOutcome = outcomes.contains(.didnt) ? .didnt : outcomes.contains(.unknown) ? .unknown : .worked
		return BatchReport(outcome: outcome, steps: steps, stoppedAt: outcome == .didnt ? steps.count - 1 : nil, deltaSource: .snapshot, verification: nil, rootDelta: rootDelta)
	}

	func waitFor(_ request: WaitForRequest) throws -> WaitOutcome {
		let wait = update { scene in
			scene.waits.append(request)
			return scene.wait
		}
		return wait(request)
	}

	func readText(_ handle: Handle, offset: Int, limit: Int) throws -> TextPage {
		let read = update { scene in
			scene.reads.append(handle)
			return scene.read
		}
		let value = read(handle)
		return TextPage(text: String(value.dropFirst(offset).prefix(limit)), offset: offset, limit: limit, totalChars: value.count, hasMore: offset + limit < value.count)
	}

	func diagnostics() -> Diagnostics {
		Diagnostics(accessibility: scene.permissions, screenRecording: scene.permissions, pid: 1, parentPid: 1, parentPath: nil, parentAppName: nil, parentBundleId: nil, executablePath: "/Applications/bcu.app/Contents/MacOS/bcu", macOS: "27", arch: "arm64")
	}

	func checkPermissions() -> PermissionStatus {
		let granted = scene.permissions
		return PermissionStatus(accessibility: granted, screenRecording: granted, screenRecordingPreflight: granted, source: PermissionSource(pid: 1, parentPid: 1, parentPath: nil, parentBundleId: nil, executablePath: "/Applications/bcu.app/Contents/MacOS/bcu", macOS: "27", attribution: .bcuApp))
	}

	func registerPermissions() -> PermissionRegistration {
		PermissionRegistration(accessibility: scene.permissions, screenRecording: scene.permissions)
	}
}

// MARK: - building scenes

func root(_ handle: String, pid: Int32, app: String, bundleId: String? = nil, kind: RootKind = .window, title: String, role: String = "AXWindow", subrole: String = "AXStandardWindow", windowId: UInt32? = nil, frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600), zOrder: Int = 0, focused: Bool = false, main: Bool = false, modal: Bool = false) -> Root {
	Root(kind: kind, handle: Handle(handle), windowId: windowId, zOrder: zOrder, title: title, role: role, subrole: subrole, isModal: modal, framePoints: frame, scaleFactor: 2, isMinimized: false, isOnscreen: true, isMain: main, isFocused: focused, metadata: kind == .menubar ? nil : RootMetadata(pairing: RootPairing(confidence: .exact, score: 110), sheetCount: 0), pid: pid, appName: app, bundleId: bundleId)
}

/// A node whose element handle is named `handle`; nil makes a line read from the screen.
func node(_ handle: String?, role: String, title: String = "", value: String = "", canPress: Bool = false, canSetValue: Bool = false, rect: CGRect = CGRect(x: 0, y: 0, width: 50, height: 20), offscreen: Bool = false, truncated: Bool = false, children: [LookNode] = []) -> LookNode {
	let node = LookNode(handle: handle.map { Handle($0) }, name: handle == nil ? "ocr_1" : "", role: role, subrole: "", identifier: "", title: title, description: "", value: value, actions: canPress ? ["AXPress"] : [], canPress: canPress, canFocus: canSetValue, canSetValue: canSetValue, canScroll: false, canIncrement: false, canDecrement: false, isTextInput: canSetValue, rect: rect, offscreen: offscreen, pictureOnly: handle == nil)
	node.truncated = truncated
	node.children = children
	return node
}

/// A recorded outline as a look returns it; each element's handle is named after its wire ref.
func node(_ serialized: SerializedOutlineNode, values: [String: String]) -> LookNode {
	let rect = serialized.rect.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) } ?? .zero
	let handle = serialized.pictureOnly ? nil : serialized.wireRef.map { Handle($0) }
	let node = LookNode(handle: handle, name: handle == nil ? serialized.wireRef ?? "" : "", role: serialized.role, subrole: serialized.subrole, identifier: serialized.identifier, title: serialized.title, description: serialized.description, value: serialized.wireRef.flatMap { values[$0] } ?? serialized.value, actions: serialized.actions, canPress: serialized.canPress, canFocus: serialized.canFocus, canSetValue: serialized.canSetValue, canScroll: serialized.canScroll, canIncrement: serialized.canIncrement, canDecrement: serialized.canDecrement, isTextInput: serialized.isTextInput, rect: rect, focused: serialized.focused, offscreen: serialized.offscreen, pictureOnly: serialized.pictureOnly)
	node.truncated = serialized.truncated
	node.scrollExtent = serialized.scrollExtent
	node.children = serialized.children.map { BCUDaemonTests.node($0, values: values) }
	return node
}

func fixture(_ name: String) throws -> SerializedOutline {
	let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/fixtures/\(name)-outline.json").standardizedFileURL
	return try JSONCoding.decode(SerializedOutline.self, from: JSONValue(parsing: String(contentsOf: url, encoding: .utf8)))
}

func lookResult(_ outline: LookNode, frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600), windowId: UInt32 = 0, kind: RootKind = .window, image: Bool = false, readText: ReadTextMode = .auto, readScreen: Bool = false) -> LookResult {
	let jpeg = image ? LookImage(jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]), width: Int(frame.width), height: Int(frame.height)) : nil
	return LookResult(
		capturedAt: Date(),
		window: LookWindow(windowId: windowId, kind: kind, framePoints: frame, scaleFactor: 2, isModal: false, metadata: RootMetadata(pairing: RootPairing(confidence: .exact, score: 110), sheetCount: 0), role: "AXWindow", subrole: "AXStandardWindow"),
		outline: outline,
		geometry: LookGeometry(windowId: windowId, windowFrame: frame, imageWidth: Int(frame.width), imageHeight: Int(frame.height), hasImage: jpeg != nil),
		timings: LookTimings(captureMs: 0, describeMs: 0, readTextMs: 0),
		readText: (readText, readScreen),
		image: jpeg
	)
}

func reported(_ outcome: ActOutcome, _ delivery: Delivery = .ax, evidence: ActEvidence? = nil, delta: [RootChange] = []) -> ActionReport {
	var report = ActionReport(outcome: outcome, performed: ActPerformed(delivery: delivery), verification: evidence)
	report.rootDelta = delta
	return report
}

func handle(of target: ActTarget) -> Handle? {
	if case .element(let handle) = target { return handle }
	return nil
}

/// The daemon over a fake desktop, with its screenshots in a private directory and no pause
/// between an action and reading its effect.
struct Harness {
	let desktop: FakeDesktop
	let shots = "/tmp/bcu-daemon-test-\(UInt32.random(in: 0...UInt32.max))"
	let daemon: Daemon<FakeDesktop>

	init(_ scene: FakeDesktop.Scene) {
		desktop = FakeDesktop(scene)
		daemon = Daemon(desktop: desktop, artifacts: ArtifactStore(directory: shots), pause: { _ in })
	}

	func json(_ request: String) async throws -> JSONValue {
		try await daemon.handle(.command(try JSONCoding.decode(CommandRequest.self, from: JSONValue(parsing: request))))
	}

	func run(_ request: String) async throws -> CommandResult {
		let decoded = try JSONCoding.decode(CommandRequest.self, from: JSONValue(parsing: request))
		return try CommandResult.decode(decoded.name, from: try await daemon.handle(.command(decoded)))
	}

	/// The text view the CLI prints for a command.
	func text(_ request: String) async throws -> String {
		try CLI.output(try await run(request), json: false)
	}

	func plain(_ command: PlainCommand) async throws -> JSONValue {
		try await daemon.handle(.plain(command))
	}

	func roots(_ params: String) async throws -> [RootInfo] {
		guard case .findRoots(let result) = try await run(#"{"command":"find-roots","params":\#(params)}"#) else { throw BCUError(.internalError, "not a listing") }
		return result.roots
	}

	func observe(_ params: String) async throws -> ObserveResult {
		guard case .observeUi(let result) = try await run(#"{"command":"observe-ui","params":\#(params)}"#) else { throw BCUError(.internalError, "not an observation") }
		return result
	}

	func act(_ stateId: String, _ actions: String, _ extra: String = "") async throws -> ActResult {
		guard case .actUi(let result) = try await run(actRequest(stateId, actions, extra)) else { throw BCUError(.internalError, "not an act") }
		return result
	}

	func actRequest(_ stateId: String, _ actions: String, _ extra: String = "") -> String {
		#"{"command":"act-ui","params":{"stateId":"\#(stateId)","actions":\#(actions)\#(extra)}}"#
	}
}

func expectCode(_ code: ErrorCode, _ body: () async throws -> Void) async -> Bool {
	do {
		try await body()
		return false
	} catch let error as BCUError {
		return error.code == code
	} catch {
		return false
	}
}
