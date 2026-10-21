/// Observations and the queries over them: observe-ui, search-ui, expand-ui, inspect-ui,
/// read-text and wait-for.
import BCUCore
import BCUPlatform
import BCURuntime
import Foundation
import os

/// Image size for a look nobody asked a picture of, and for an explicit `--image always`.
let automaticImageDimension = 900
let explicitImageDimension = 1_600

/// A look's picture, carried out of the lane that saved the look until its stateId names the file.
private final class CapturedImage: Sendable {
	private let image = OSAllocatedUnfairLock<LookImage?>(initialState: nil)

	var value: LookImage? {
		get { image.withLock { $0 } }
		set { image.withLock { $0 = newValue } }
	}
}

extension Daemon {
	/// Looks at a root and builds the observation to save. Against a base observation of the
	/// same root, refs of what is still there are kept.
	/// `image` asks for a picture at the size an explicit request gets; the platform may take
	/// one anyway to read the screen.
	/// `until` ends a wait for a browser's web content at the caller's own deadline.
	func capture(_ target: Target, readText: ReadTextMode = .auto, image: ImageMode = .never, base: Observation? = nil, until deadline: Date? = nil) async throws -> (observation: Observation, image: LookImage?) {
		try await capture(target, readText: readText, includeImage: image == .always, maxDimension: image == .always ? explicitImageDimension : automaticImageDimension, base: base, until: deadline)
	}

	func capture(_ target: Target, readText: ReadTextMode, includeImage: Bool, maxDimension: Int, base: Observation?, until deadline: Date? = nil) async throws -> (observation: Observation, image: LookImage?) {
		let request = LookRequest(
			root: target.root.handle, windowId: target.root.windowId.flatMap { $0 > 0 ? $0 : nil },
			maxDimension: maxDimension, readText: readText, includeImage: includeImage, deadline: deadline
		)
		let look = try await offload { [desktop = self.desktop] in try desktop.look(request) }
		let baseOutline = base.flatMap { $0.target.root.handle == target.root.handle ? $0.outline.current : nil }
		let (outline, handles) = adopt(look.outline, base: baseOutline)
		outline.stabilizeRefs(against: baseOutline.map { Outline(restoring: $0.outline) })
		let serialized = outline.serialized
		let window = look.window.framePoints
		let observation = Observation(
			target: target,
			outline: ObservedOutline(.init(outline: serialized, handles: handles)),
			geometry: look.geometry,
			image: look.image.map { ImageSize(width: max(1, $0.width), height: max(1, $0.height)) },
			readText: look.readText.requested,
			readScreen: look.readText.executed,
			webContentMissing: look.webContentMissing,
			frame: Frame(x: window.origin.x, y: window.origin.y, w: max(0, window.width), h: max(0, window.height)),
			scale: max(1, look.window.scaleFactor),
			byteCount: try JSONCoding.string(serialized).utf8.count
		)
		return (observation, look.image)
	}

	/// The screenshot a look took, written as the state's artifact.
	func artifact(_ image: LookImage?, for stateId: String) async throws -> ImageInfo? {
		guard let image else { return nil }
		let path = try await artifacts.save(stateId: stateId, bytes: image.jpeg, mime: "image/jpeg")
		return ImageInfo(path: path, mime: "image/jpeg", width: max(1, image.width), height: max(1, image.height))
	}

	// MARK: observe-ui

	func observe(_ params: ObserveParams) async throws -> ObserveResult {
		let image = params.image ?? (params.mode == .fused ? .always : .never)
		let target = try await observedTarget(params.selector)
		let observed = try await observation(of: target, readText: params.readText ?? .auto, image: image)
		let observation = observed.state.payload
		let root = RootSummary(ref: target.ref, app: target.appName, pid: Int(target.pid), title: target.title, windowId: target.windowId, frame: observation.frame, scale: observation.scale)
		return observeResult(stateId: observed.state.stateId, root: root, outline: observation.outline.outline(), image: try await artifact(observed.image, for: observed.state.stateId), webContentMissing: observation.webContentMissing)
	}

	/// Looks at a root and saves the look as a live state in its app's lane.
	func observation(of target: Target, readText: ReadTextMode = .auto, image: ImageMode = .never, until deadline: Date? = nil) async throws -> (state: StoredState<Observation>, image: LookImage?) {
		let picture = CapturedImage()
		let state = try await runtime.observe(pid: Int(target.pid)) { _ in
			let captured = try await self.capture(target, readText: readText, image: image, until: deadline)
			picture.value = captured.image
			return captured.observation
		}
		return (state, picture.value)
	}

	/// The state a command runs against: the saved one it names, or a fresh observation of
	/// the root it selects.
	func state(_ command: CommandName, stateId: String?, selector: RootSelector?) async throws -> StoredState<Observation> {
		switch try Subject(command, stateId: stateId, selector: selector) {
		case .state(let stateId): try runtime.state(stateId)
		case .fresh(let selector): try await observation(of: try await observedTarget(selector)).state
		}
	}

	// MARK: cached queries

	/// Searches the saved outline. When nothing found can be acted on and the screen was not
	/// read yet, the root is read from the screen once and the search runs on that new state.
	func search(_ params: SearchUiParams) async throws -> SearchResult {
		let state = try await state(.searchUi, stateId: params.stateId, selector: params.selector)
		let found = try searchUI(params, in: state.payload.outline.outline(), stateId: state.stateId)
		let hits = searchOutline(state.payload.outline.outline(), text: trimmed(params.text), role: trimmed(params.role))
		let nothingToActOn = hits.allSatisfy { !$0.canPress && !$0.canFocus && !$0.canSetValue && $0.actions.isEmpty && !$0.pictureOnly }
		guard nothingToActOn, state.payload.readText != .never, !state.payload.readScreen else { return found }
		try await ensureUnlocked()
		// The screen is read into a new state and no ref of this one is resolved, so an action
		// since this state was observed changes nothing: the new look is taken as things are now.
		let read = try await runtime.live(pid: state.pid) { lane in
			let target = try await self.current(state.payload.target)
			// Lines read from the screen are pressed by coordinates, which need the picture.
			return try lane.save(try await self.capture(target, readText: .always, includeImage: true, maxDimension: automaticImageDimension, base: state.payload).observation)
		}
		return try searchUI(params, in: read.payload.outline.outline(), stateId: read.stateId)
	}

	/// Expands a node of the saved outline. A subtree the platform cut short is read live and
	/// grafted into the saved observation, so its refs stay valid for later commands.
	func expand(_ params: ExpandUiParams) async throws -> ExpandResult {
		let state = try runtime.state(params.stateId)
		guard let ref = trimmed(params.ref) else { throw BCUError(.invalidArguments, "expand-ui requires --ref.") }
		guard let node = state.payload.outline.outline().node(ref) else { throw BCUError(.elementNotFound, "Ref '\(ref)' is not in the current state.") }
		if node.truncated {
			try await ensureUnlocked()
			try await runtime.read(from: state.stateId) { state, _ in
				let observation = state.payload
				let target = try await self.current(observation.target)
				let outline = observation.outline.outline()
				guard let node = outline.node(ref) else { throw BCUError(.elementNotFound, "Ref '\(ref)' is not in the current state.") }
				let request = LookRequest(root: target.root.handle, windowId: target.root.windowId, maxDimension: 1, readText: .auto, baseGeometry: observation.geometry, includeImage: false, scope: try observation.outline.handle(of: node))
				let look = try await offload { [desktop = self.desktop] in try desktop.look(request) }
				let scoped = adopt(look.outline, base: observation.outline.current)
				try outline.graft(scoped.outline, at: node.ref)
				observation.outline.replace(outline, adding: scoped.handles)
			}
		}
		return try expandUI(params, in: state.payload.outline.outline(), stateId: state.stateId) { _ in
			throw BCUError(.internalError, "A cut-short subtree was left unread.")
		}
	}

	func inspect(_ params: InspectUiParams) throws -> InspectResult {
		let state = try runtime.state(params.stateId)
		return try inspectUI(params, in: state.payload.outline.outline(), stateId: state.stateId)
	}

	/// A node of the saved state, as actions and reads name it.
	func node(_ ref: String, in outline: Outline) throws -> OutlineNode {
		guard let node = outline.node(ref) else {
			throw BCUError(.elementNotFound, "Ref '\(ref)' does not belong to the current state. Observe the root again and use a ref from the new state.")
		}
		return node
	}

	func readText(_ params: ReadTextParams) async throws -> BCUCore.ReadTextResult {
		let state = try runtime.state(params.stateId)
		guard let ref = trimmed(params.ref) else { throw BCUError(.invalidArguments, "read-text requires --ref.") }
		let handle = try state.payload.outline.handle(of: try node(ref, in: state.payload.outline.outline()))
		let offset = max(0, params.offset ?? 0)
		let limit = max(1, min(100_000, params.limit ?? 4_000))
		let page = try await runtime.read(from: state.stateId) { _, _ in
			try await offload { [desktop = self.desktop] in try desktop.readText(handle, offset: offset, limit: limit) }
		}
		return BCUCore.ReadTextResult(stateId: state.stateId, ref: ref, offset: page.offset, limit: page.limit, total: page.totalChars, text: page.text)
	}

	// MARK: wait-for

	func waitFor(_ params: WaitForParams) async throws -> BCUCore.WaitForResult {
		let text = trimmed(params.text)
		let role = trimmed(params.role)
		let timeoutMs = waitTimeout(params.timeoutMs)
		guard text != nil || role != nil else { throw BCUError(.invalidArguments, "wait-for requires --text or --role.") }
		let clock = Countdown(timeoutMs: timeoutMs)
		let overrun = BCUError(.actionTimeout, "wait-for did not finish within \(timeoutMs)ms: the app was too slow to answer.", recovery: "Observe the root again, or retry with a longer --timeout.")
		return try await answering(by: clock.deadline.addingTimeInterval(waitGrace), else: overrun) {
			try await self.waitFor(params, text: text, role: role, timeoutMs: timeoutMs, clock: clock)
		}
	}

	private func waitFor(_ params: WaitForParams, text: String?, role: String?, timeoutMs: Int, clock: Countdown) async throws -> BCUCore.WaitForResult {
		let state: StoredState<Observation>
		switch try Subject(.waitFor, stateId: params.stateId, selector: params.selector) {
		case .state(let stateId): state = try runtime.state(stateId)
		case .fresh(let selector):
			if trimmed(params.scope) != nil { throw stateRefs("--scope") }
			let root = try await awaitRoot(selector, clock, timeoutMs: timeoutMs)
			state = try await observation(of: root, until: clock.deadline).state
			// The observation used the time up; looking for the condition would only overrun it.
			guard clock.remainingMs > 0 else { throw conditionTimedOut(params, timeoutMs: timeoutMs) }
		}
		let scope = try trimmed(params.scope).map { try state.payload.outline.handle(of: try node($0, in: state.payload.outline.outline())) }
		// A scope is a ref, and a ref belongs to the state that made it: that state must still be
		// current, before the wait and after it. Without one, the state only names the root; an
		// action since, the one that makes the condition hold included, does not fail the wait.
		if scope != nil { try await runtime.read(from: state.stateId) { _, _ in } }
		let target = try await current(state.payload.target)
		let gone = params.gone == true
		let request = WaitForRequest(pid: target.pid, root: target.root.handle, role: role, text: text, gone: gone, scope: scope, timeoutMs: clock.remainingMs)
		let outcome = try await offload { [desktop = self.desktop] in try desktop.waitFor(request) }
		guard outcome == .found || outcome == .gone else { throw conditionTimedOut(params, timeoutMs: timeoutMs) }
		let look: @Sendable (Lane<Observation>) async throws -> StoredState<Observation> = { lane in
			try lane.save(try await self.capture(target, base: state.payload, until: clock.deadline).observation)
		}
		let successor = scope == nil
			? try await runtime.live(pid: state.pid, look)
			: try await runtime.read(from: state.stateId) { _, lane in try await look(lane) }
		let view = successorView(base: state.payload.outline.outline(), next: successor.payload.outline.outline())
		return BCUCore.WaitForResult(stateId: successor.stateId, found: true, gone: outcome == .gone ? true : nil, changes: view.changes, offscreen: view.offscreen, nodes: view.nodes, shown: view.shown, total: view.total)
	}
}

/// Past the deadline, how long a wait-for may take to finish what it started before it answers
/// anyway: the look in progress stops at the deadline, but not inside an accessibility request,
/// which an app slow to answer holds for up to its messaging timeout.
private let waitGrace: TimeInterval = 1

/// Runs `body`, but answers by `deadline` whatever it is doing: a platform call blocks in an
/// accessibility request for as long as the app takes to answer, up to its messaging timeout,
/// and nothing can interrupt it. What it started then finishes unheeded; its lane stays busy
/// until it does.
private func answering<T: Sendable>(by deadline: Date, else overrun: BCUError, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
	try await withCheckedThrowingContinuation { continuation in
		let answered = OSAllocatedUnfairLock(initialState: false)
		let answer: @Sendable (Result<T, any Error>) -> Void = { result in
			if answered.withLock({ done in defer { done = true }; return !done }) { continuation.resume(with: result) }
		}
		let timer = Task {
			try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
			answer(.failure(overrun))
		}
		Task {
			do { answer(.success(try await body())) } catch { answer(.failure(error)) }
			timer.cancel()
		}
	}
}

private func conditionTimedOut(_ params: WaitForParams, timeoutMs: Int) -> BCUError {
	let inside = params.scope.map { " inside \($0)" } ?? ""
	return BCUError(.actionTimeout, "The condition \(params.gone == true ? "still held" : "did not appear") within \(timeoutMs)ms\(inside).")
}

/// Condition timeouts: 10 s unless given, between 0.1 s and 60 s.
func waitTimeout(_ requested: Int?) -> Int {
	max(100, min(60_000, requested ?? 10_000))
}
