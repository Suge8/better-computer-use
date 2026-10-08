/// What makes act-ui work across user interface: steps that name their element and find it when
/// they run, roots chosen by what the earlier steps opened, a step's own postcondition, and the
/// view of a root left open. See "Action transaction" in docs/architecture.md.
import BCUCore
import BCUPlatform
import BCURuntime
import Foundation

/// An action ready to deliver, with the root it acts in and the look its coordinates come from.
struct ResolvedStep: Sendable {
	let action: ActAction
	let target: ActTarget
	let input: ActionInput
	let root: Target
	let geometry: LookGeometry
}

enum Step: Sendable {
	case wait(ms: Int)
	case deliver(ResolvedStep)
	/// Names its element; found in a fresh look of its root when it runs.
	case locate(UiAction)
}

struct PlannedStep: Sendable {
	let step: Step
	let expect: Expectation?
}

/// What the steps delivered so far opened: the roots the app had before the array started,
/// and the roots each step reported appearing.
struct Trail: Sendable {
	var known: Set<Handle>
	var appeared: [[Root]] = []
}

/// How long a step waits for its element to appear unless it says otherwise.
private let defaultLocateTimeoutMs = 3_000
/// Between two looks that found nothing yet: a notification ends the wait at once, and this cap
/// stands in for the ones macOS never posts (a sheet appearing).
private let lookCapMs = 400

/// Kinds of root an action leaves open that the agent continues in; a new window is observed on request.
private let attachedKinds: Set<RootKind> = [.menu, .sheet, .popover, .dialog]

private struct Countdown {
	private let clock = ContinuousClock()
	private let deadline: ContinuousClock.Instant

	init(timeoutMs: Int) {
		deadline = clock.now + .milliseconds(timeoutMs)
	}

	var remainingMs: Int {
		let left = deadline - clock.now
		return max(0, Int(left.components.seconds * 1_000 + left.components.attoseconds / 1_000_000_000_000_000))
	}
}

extension Daemon {
	// MARK: finding an element

	/// Looks at the root the locator names until it holds exactly one match, and prepares the
	/// action on it. A miss is awaited; ambiguity is not.
	func locateStep(_ action: UiAction, index: Int, count: Int, base: Target, trail: Trail, headless: Bool) async throws -> ResolvedStep {
		guard let locator = action.find else { throw BCUError(.internalError, "Step \(index + 1) has no locator.") }
		let timeoutMs = locator.timeoutMs ?? defaultLocateTimeoutMs
		let clock = Countdown(timeoutMs: timeoutMs)
		return try await inStep(index, count) {
			while true {
				let watch = await self.watch(base.pid)
				let root = try await self.rootTarget(locator.root ?? .state, base: base, trail: trail, timeoutMs: clock.remainingMs)
				let observation = try await self.capture(root).observation
				let outline = observation.outline.outline()
				switch locate(locator, for: action.action, in: outline) {
				case .found(let ref):
					var resolved = action
					(resolved.ref, resolved.find, resolved.expect) = (ref, nil, nil)
					let environment = ActionEnvironment(outline: outline, image: observation.image, headless: headless)
					let prepared = try prepareAction(resolved, state: ActionState(currentFocus: false), environment: environment)
					return try self.resolvedStep(prepared, outline: outline, observation: observation, root: root)
				case .ambiguous(let error): throw error
				case .missing(let error):
					guard clock.remainingMs > 0 else { throw error }
					try await self.settle(watch, pid: base.pid, ms: min(clock.remainingMs, lookCapMs))
				}
			}
		}
	}

	func resolvedStep(_ prepared: PreparedAction, outline: Outline, observation: Observation, root: Target) throws -> ResolvedStep {
		var preserveFocus = false
		let target: ActTarget
		switch prepared.target {
		case .ref(let wireRef):
			guard let node = outline.node(wireRef) else { throw BCUError(.elementNotFound, "Ref '\(wireRef)' does not belong to the current state.") }
			target = .element(try observation.outline.handle(of: node))
		case .point(let point):
			target = .point(x: point.x, y: point.y)
		case .focus(let x, let y):
			// Typing into whatever an earlier click focused; the point only anchors the input.
			target = .point(x: Double(x), y: Double(y))
			preserveFocus = true
		case nil:
			throw BCUError(.internalError, "Action \(prepared.action.rawValue) was prepared without a target.")
		}
		guard let action = ActAction(rawValue: prepared.action.rawValue) else {
			throw BCUError(.invalidArguments, "Action \(prepared.action.rawValue) cannot be delivered.")
		}
		return ResolvedStep(action: action, target: target, input: actionInput(prepared.params, preserveFocus: preserveFocus), root: root, geometry: observation.geometry)
	}

	private func actionInput(_ params: PreparedParams, preserveFocus: Bool) -> ActionInput {
		switch params {
		case .click(let button, let clickCount):
			ActionInput(button: button == .right ? .right : button == .middle ? .center : .left, clickCount: clickCount, preserveFocus: preserveFocus)
		case .text(let text): ActionInput(text: text, preserveFocus: preserveFocus)
		case .keys(let keys): ActionInput(keys: keys, preserveFocus: preserveFocus)
		case .scroll(let x, let y): ActionInput(scrollX: x, scrollY: y, preserveFocus: preserveFocus)
		case .drag(let path): ActionInput(path: path.map { CGPoint(x: $0.x, y: $0.y) }, preserveFocus: preserveFocus)
		case .none, .wait: ActionInput(preserveFocus: preserveFocus)
		}
	}

	// MARK: roots a step looks in

	/// The root of a choice: the state's own, what the earlier steps opened most recently (waited
	/// for when nothing has opened yet), or what the app would be observed at now.
	func rootTarget(_ choice: RootChoice, base: Target, trail: Trail, timeoutMs: Int) async throws -> Target {
		switch choice {
		case .state: return try await current(base)
		case .opened: return try await openedRoot(base: base, trail: trail, timeoutMs: timeoutMs)
		case .app:
			guard let best = mostProminent(try await roots(pid: base.pid)) else {
				throw BCUError(.windowStale, "App '\(base.appName)' has no controllable root to look in.")
			}
			return target(best, appName: base.appName, bundleId: base.bundleId)
		}
	}

	private func openedRoot(base: Target, trail: Trail, timeoutMs: Int) async throws -> Target {
		let clock = Countdown(timeoutMs: timeoutMs)
		while true {
			let watch = await self.watch(base.pid)
			let live = try await roots(pid: base.pid)
			let reported = trail.appeared.reversed().lazy.compactMap { step in mostProminent(live.filter { root in step.contains { $0.handle == root.handle } }) }.first
			if let opened = reported ?? mostProminent(live.filter { !trail.known.contains($0.handle) }) {
				return target(opened, appName: base.appName, bundleId: base.bundleId)
			}
			guard clock.remainingMs > 0 else {
				throw BCUError(.elementNotFound, "No root was opened by the earlier steps of this array.", recovery: "Check that the earlier step opens a dialog, menu or window, or raise the timeoutMs of this step.")
			}
			try await settle(watch, pid: base.pid, ms: min(clock.remainingMs, lookCapMs))
		}
	}

	// MARK: waiting between looks

	struct Watch: Sendable {
		let mark: ChangeMark?
		let failure: BCUError?
	}

	/// Taken before a look; an app that accepts no observer fails only when a wait is needed.
	func watch(_ pid: Int32) async -> Watch {
		do {
			return Watch(mark: try await offload { [desktop = self.desktop] in try desktop.changeMark(pid: pid) }, failure: nil)
		} catch {
			return Watch(mark: nil, failure: BCUError.normalize(error))
		}
	}

	func settle(_ watch: Watch, pid: Int32, ms: Int) async throws {
		guard let mark = watch.mark else { throw watch.failure ?? BCUError(.internalError, "A watch has neither a mark nor a failure.") }
		try await offload { [desktop = self.desktop] in try desktop.waitForChange(pid: pid, since: mark, timeoutMs: ms) }
	}

	// MARK: a step's own postcondition

	/// Checks the condition in the root it names, the step's own by default. A root the step
	/// closed holds nothing to check: only an expected disappearance is met.
	func verifyStep(_ expect: Expectation, index: Int, count: Int, acted: Target, base: Target, closed: Bool, trail: Trail) async throws {
		let timeoutMs = waitTimeout(expect.timeoutMs)
		try await inStep(index, count) {
			var root = acted
			if let choice = expect.root { root = try await self.rootTarget(choice, base: base, trail: trail, timeoutMs: timeoutMs) }
			if closed, root.root.handle == acted.root.handle {
				guard expect.gone == true else {
					throw BCUError(.actionFailed, "The root the step ran in closed, so its postcondition could not be checked.")
				}
				return
			}
			let request = WaitForRequest(pid: root.pid, root: root.root.handle, role: trimmed(expect.role), text: trimmed(expect.text), value: trimmed(expect.value), gone: expect.gone == true, timeoutMs: timeoutMs)
			let outcome = try await offload { [desktop = self.desktop] in try desktop.waitFor(request) }
			guard outcome == .found || outcome == .gone else {
				throw BCUError(.actionFailed, "The step was delivered but its postcondition was not satisfied within \(timeoutMs)ms.", recovery: "Observe the current UI before deciding whether the step is safe to retry.")
			}
		}
	}

	/// Failures of a step name it and say how much of the array was already delivered, since
	/// delivered steps are never replayed.
	private func inStep<T: Sendable>(_ index: Int, _ count: Int, _ body: () async throws -> T) async throws -> T {
		do {
			return try await body()
		} catch let error as BCUError where count > 1 {
			let delivered = index == 0 ? "" : index == 1 ? " Step 1 was already delivered and is not replayed." : " Steps 1–\(index) were already delivered and are not replayed."
			throw BCUError(error.code, "Step \(index + 1) of \(count): \(error.message)", recovery: error.recovery + delivered)
		}
	}

	// MARK: a root left open

	/// The view of the most prominent menu, sheet, popover or dialog the actions opened and
	/// left open, saved as a state of its own in the same lane as the successor.
	func attachOpened(_ appeared: [Root], base: Target, lane: Lane<Observation>) async throws -> (opened: OpenedRoot, element: Handle?)? {
		let candidates = appeared.filter { $0.pid == base.pid && attachedKinds.contains($0.kind) }
		guard let best = mostProminent(candidates) else { return nil }
		let root = target(best, appName: base.appName, bundleId: base.bundleId)
		let observation: Observation
		do {
			observation = try await capture(root, readText: .never).observation
		} catch {
			if try await isLive(root) { throw error }
			return nil
		}
		let saved = try lane.save(observation)
		let outline = saved.payload.outline.outline()
		let view = BCUCore.openedView(outline)
		let opened = OpenedRoot(root: root.appearance, stateId: saved.stateId, nodes: view.nodes ?? [], shown: view.shown ?? 0, total: view.total ?? 0)
		return (opened, outline.root.wireRef.flatMap { saved.payload.outline.current.handles[$0] })
	}
}
