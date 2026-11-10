/// act-ui: a checked action array delivered to one saved state's root as one transaction, up
/// the delivery ladder, judged on evidence, and answered with the successor state. See
/// "投递梯子" and "Action transaction" in docs/architecture.md.
import BCUCore
import BCUPlatform
import BCURuntime
import Foundation

/// How long to let the UI settle after an action whose platform result did not already wait
/// for it: background accessibility delivery settles faster than raw input.
private let settleAfterRawInput = Duration.milliseconds(280)
private let settleAfterAccessibility = Duration.milliseconds(120)

/// Everything checked before the epoch moves: the transaction is refused, not half delivered,
/// when any of it fails. A step that names its element is found only when it runs, but the
/// first one is found here: refusing it costs the caller nothing.
private struct Transaction: Sendable {
	let target: Target
	let steps: [PlannedStep]
	let scope: Handle?
	let base: Observation
	let baseStateId: String
	/// The roots the app showed before the array ran; read only when a step looks for what an earlier one opened.
	let known: Set<Handle>
	var outline: SerializedOutline { base.outline.current.outline }
}

/// A root the actions acted in, and the element it is seen as inside another root's tree.
struct ActedRoot: Sendable {
	let target: Target
	let element: Handle?
}

/// What happened while the actions were delivered.
private struct Execution {
	var outcome: ActOutcome
	var evidence: BCUCore.ActEvidence?
	var appeared: [Root] = []
	/// The roots the steps acted in, each once.
	var acted: [ActedRoot] = []
	/// How the last step was delivered: `ax`, `pid` or `hid`.
	var delivery: String?
	/// The platform already waited for the UI to settle.
	var settled = false
	/// Every step went through background accessibility.
	var quiet: Bool
	var openedMenus = false
	/// bcu activated the app, or moved the real pointer, to deliver.
	var activated = false
	var movedPointer = false
	/// A value written into a web text area that the app may not have taken yet.
	var uncommitted = false
	var actionCount: Int
	/// The step closed the root it acted in.
	var rootClosed = false
	/// The postcondition of the last step that had one and met it.
	var verified: Expectation?

	/// One array: the worst outcome, the last evidence, every root opened.
	init(_ steps: [Execution]) {
		let outcomes = steps.map(\.outcome)
		outcome = outcomes.contains(.didnt) ? .didnt : outcomes.contains(.unknown) ? .unknown : .worked
		evidence = steps.last { $0.evidence != nil }?.evidence
		appeared = merged(steps.flatMap(\.appeared))
		acted = distinct(steps.flatMap(\.acted))
		delivery = steps.last?.delivery
		quiet = steps.allSatisfy(\.quiet)
		openedMenus = steps.contains(where: \.openedMenus)
		activated = steps.contains(where: \.activated)
		movedPointer = steps.contains(where: \.movedPointer)
		uncommitted = steps.contains(where: \.uncommitted)
		actionCount = steps.count
		verified = steps.last { $0.verified != nil }?.verified
		settled = steps.last?.settled ?? false
	}

	/// One step, as the platform reported it.
	init(_ report: ActionReport, in step: ResolvedStep, headless: Bool) {
		outcome = report.outcome
		evidence = report.verification
		appeared = report.rootDelta.compactMap { if case .root(.appeared, let root) = $0 { root } else { nil } }
		acted = [ActedRoot(target: step.root, element: step.rootElement)]
		delivery = report.performed.delivery.rawValue
		settled = report.performed.deltaSource != nil
		quiet = headless || report.performed.delivery == .ax
		openedMenus = report.performed.openedMenus
		activated = report.performed.activated == true
		movedPointer = report.performed.movedPointer
		uncommitted = report.performed.valueUncommitted
		actionCount = 1
		rootClosed = report.rootDelta.contains { if case .root(.closed, let root) = $0 { root.handle == step.root.root.handle } else { false } }
	}

	init(waited: Void) {
		outcome = .worked
		settled = true
		quiet = true
		actionCount = 1
	}
}

/// One root per identity, whichever step opened it.
private func merged(_ roots: [Root]) -> [Root] {
	var order: [Handle] = []
	var latest: [Handle: Root] = [:]
	for root in roots {
		if latest[root.handle] == nil { order.append(root.handle) }
		latest[root.handle] = root
	}
	return order.map { latest[$0]! }
}

/// One entry per root.
private func distinct(_ roots: [ActedRoot]) -> [ActedRoot] {
	roots.reduce(into: []) { kept, root in
		if !kept.contains(where: { $0.target.root.handle == root.target.root.handle }) { kept.append(root) }
	}
}

extension Daemon {
	func act(_ params: ActParams) async throws -> BCUCore.ActResult {
		let actions = try validateActions(params.actions.map { try JSONCoding.encode($0) })
		let subject = try Subject(.actUi, stateId: params.stateId, selector: params.selector)
		if case .fresh = subject { try requireStateFree(actions, scope: params.expect?.scope) }
		let headless = params.headless ?? false
		let foreground = params.foreground ?? false
		if headless && foreground {
			throw BCUError(.invalidArguments, "--foreground contradicts headless, which forbids activating the app.")
		}
		let image = params.image ?? .never
		if let expect = params.expect, trimmed(expect.text) == nil, trimmed(expect.role) == nil, trimmed(expect.value) == nil {
			throw BCUError(.invalidArguments, "act-ui expectations require --expect-text, --expect-role, or --expect-value.")
		}
		let prepare: @Sendable (StoredState<Observation>) async throws -> Transaction = { state in
			try await self.prepare(actions, params: params, headless: headless, state: state)
		}
		let deliver: @Sendable (Transaction, Lane<Observation>) async throws -> BCUCore.ActResult = { transaction, lane in
			try await self.deliver(transaction, actions: actions, params: params, headless: headless, image: image, lane: lane)
		}
		switch subject {
		case .state(let stateId):
			return try await runtime.act(from: stateId, prepare: prepare, deliver: deliver)
		case .fresh(let selector):
			// The command's own look is taken in the turn that delivers: another client's action
			// cannot come between them and stale a state nobody else holds.
			let target = try await observedTarget(selector)
			return try await runtime.act(observing: Int(target.pid), { _ in try await self.capture(target).observation }, prepare: prepare, deliver: deliver)
		}
	}

	private func prepare(_ actions: [UiAction], params: ActParams, headless: Bool, state: StoredState<Observation>) async throws -> Transaction {
		let observation = state.payload
		let outline = observation.outline.outline()
		// Scope refs belong to the base state, so they are resolved before the UI moves.
		let scope = try trimmed(params.expect?.scope).map { try observation.outline.handle(of: try node($0, in: outline)) }
		let target = try await current(observation.target)
		let environment = ActionEnvironment(outline: outline, image: observation.image, capturableRoot: observation.target.capturableRef, headless: headless)
		let looksForOpened = actions.contains { $0.find?.root == .opened || $0.expect?.root == .opened }
		let known = looksForOpened ? Set(try await roots(pid: target.pid).map(\.handle)) : []
		var steps: [PlannedStep] = []
		for (index, action) in actions.enumerated() {
			let step: Step
			if let locator = action.find {
				step = index == 0
					? .deliver(try await locateStep(action, locator, index: 0, count: actions.count, base: target, trail: Trail(known: known), headless: headless))
					: .locate(action, locator)
			} else {
				let prepared = try prepareAction(action, environment: environment)
				if case .wait(let ms) = prepared.params { step = .wait(ms: ms) } else { step = .deliver(try resolvedStep(prepared, outline: outline, observation: observation, root: target)) }
			}
			steps.append(PlannedStep(step: step, expect: action.expect))
		}
		return Transaction(target: target, steps: steps, scope: scope, base: observation, baseStateId: state.stateId, known: known)
	}

	private func deliver(_ transaction: Transaction, actions: [UiAction], params: ActParams, headless: Bool, image: ImageMode, lane: Lane<Observation>) async throws -> BCUCore.ActResult {
		let target = transaction.target
		let frontBefore = desktop.frontAppName()
		// Set once the steps are in; an error before that carries what the steps did itself.
		var delivered: Execution?
		do {
			// A status item opens its panel in another process (Control Center's in ControlCenter).
			let windowsBefore = target.root.kind == .statusbar ? desktop.panelWindows() : nil
			var execution = try await dispatch(transaction, actions: actions, headless: headless, startsInForeground: params.foreground ?? false)
			delivered = execution
			if params.expect == nil, !execution.settled { try await pause(execution.quiet ? settleAfterAccessibility : settleAfterRawInput) }
			if let windowsBefore {
				let panels = try await rootsOpened(elsewhere: target.pid, since: windowsBefore)
				execution.appeared = merged(execution.appeared + panels)
				if !panels.isEmpty, execution.outcome == .unknown {
					execution.outcome = .worked
					execution.evidence = BCUCore.ActEvidence(source: .root)
				}
			}
			// A root that is gone is a fact like any other; the roots the array touched are checked once, here.
			let live = Set(try await roots(pid: target.pid).map(\.handle))
			let touched = distinct([ActedRoot(target: target, element: transaction.base.outline.rootElement)] + execution.acted)
			var gone = touched.filter { !live.contains($0.target.root.handle) }
			if !gone.isEmpty {
				execution.evidence = BCUCore.ActEvidence(source: .root, field: .closed)
				if execution.outcome == .unknown { execution.outcome = .worked }
			}
			let verification = try await verification(params.expect, transaction: transaction, execution: &execution, baseLive: live.contains(target.root.handle))
			let successor = try await successor(of: transaction, baseLive: live.contains(target.root.handle), image: image)
			let foreground = foregroundEffects(activated: execution.activated, movedPointer: execution.movedPointer, before: frontBefore, after: desktop.frontAppName())
			if let successor, successor.root.root.handle != target.root.handle, !gone.contains(where: { $0.target.root.handle == target.root.handle }) {
				gone.append(touched[0])
			}
			let stillOpen = execution.appeared.filter { opened in !gone.contains { $0.target.root.handle == opened.handle } }
			let roots = stillOpen.compactMap(appearance)
			let closed = gone.isEmpty ? nil : gone.map(\.target.appearance)
			guard let successor else {
				if execution.outcome == .didnt { throw failure(execution) }
				return BCUCore.ActResult(stateId: nil, baseStateId: transaction.baseStateId, outcome: execution.outcome, verification: verification, delivery: execution.delivery ?? Delivery.ax.rawValue, foreground: foreground, roots: roots.isEmpty ? nil : roots, closed: closed)
			}
			let saved = try lane.save(successor.observation)
			let next = saved.payload.outline.outline()
			// A value read back from a web text area is no more than its own step's readback was.
			let outcome = execution.uncommitted ? execution.outcome : outcomeAfterObservedValues(execution.outcome, actions: Array(actions.prefix(execution.actionCount))) { next.node($0)?.value }
			if outcome == .didnt { throw failure(execution) }
			let attached = try await attachOpened(stillOpen, base: target, lane: lane)
			// A root hanging under another root's tree is reported as itself, in neither tree's changes.
			let elsewhere = touched.filter { $0.target.root.handle != successor.root.root.handle }.compactMap(\.element) + (attached?.element.map { [$0] } ?? [])
			let omitting = elsewhere.reduce(into: Set<String>()) { $0.formUnion(saved.payload.outline.refs(of: $1)) }
			let view: SuccessorView
			if let reference = successor.reference {
				let baseOmitting = elsewhere.reduce(into: Set<String>()) { $0.formUnion(reference.outline.refs(of: $1)) }
				view = successorView(base: reference.outline.outline(), next: next, menusOpenedByBcu: execution.openedMenus, omitting: omitting, baseOmitting: baseOmitting)
			} else {
				view = fullView(next, omitting: omitting)
			}
			return BCUCore.ActResult(
				stateId: saved.stateId, baseStateId: transaction.baseStateId, outcome: outcome, verification: verification,
				delivery: execution.delivery ?? Delivery.ax.rawValue, foreground: foreground, roots: roots.isEmpty ? nil : roots, closed: closed,
				next: successor.root.root.handle == target.root.handle ? nil : successor.root.appearance,
				opened: attached?.opened,
				changes: view.changes, offscreen: view.offscreen, nodes: view.nodes, shown: view.shown, total: view.total,
				image: try await artifact(successor.image, for: saved.stateId)
			)
		} catch var error as BCUError {
			// An action that failed may still have taken the user's front app or pointer.
			let partial = error.foreground
			error.foreground = foregroundEffects(
				activated: delivered?.activated == true || partial?.activated == true,
				movedPointer: delivered?.movedPointer == true || partial?.pointer == true,
				before: frontBefore, after: desktop.frontAppName()
			)
			throw error
		}
	}

	/// What the array is called verified: its own evidence, or the condition the caller put on
	/// it, which is checked in the state's root. A root that is gone cannot be checked; only
	/// its disappearance is a condition that holds.
	private func verification(_ expect: Expectation?, transaction: Transaction, execution: inout Execution, baseLive: Bool) async throws -> Verification {
		guard let expect else { return recordedVerification(execution) }
		if baseLive {
			do {
				return try await verify(expect, transaction: transaction, execution: &execution)
			} catch {
				if try await isLive(transaction.target) { throw error }
			}
		}
		guard expect.gone == true else {
			let delivered = execution.delivery.map { " It was delivered via \($0)." } ?? ""
			throw BCUError(.actionFailed, "The root the action ran in closed, so its postcondition could not be checked.\(delivered)")
		}
		return Verification(status: .verified, evidence: BCUCore.ActEvidence(source: .root, field: .closed), scope: trimmed(expect.scope), gone: true)
	}

	/// The root the result follows and its observation: the state's own root while it is there,
	/// else the root the app would be observed at now. The view is relative to the last time
	/// that root was seen (for the state's own, the state itself); a root never seen, or seen
	/// too long ago to be kept, has no reference and gets its whole folded view.
	private struct Successor {
		let root: Target
		let observation: Observation
		let image: LookImage?
		let reference: Observation?
	}

	private func successor(of transaction: Transaction, baseLive: Bool, image: ImageMode) async throws -> Successor? {
		var root = baseLive ? transaction.target : try await preferredRoot(after: transaction.target)
		while let candidate = root {
			let handle = candidate.root.handle
			let reference = handle == transaction.target.root.handle ? transaction.base : runtime.states.latest(pid: Int(candidate.pid)) { $0.target.root.handle == handle }?.payload
			do {
				let captured = try await capture(candidate, image: image, base: reference)
				return Successor(root: candidate, observation: captured.observation, image: captured.image, reference: reference)
			} catch {
				// The root went away between looking for it and looking at it: the next one follows.
				if try await isLive(candidate) { throw error }
				root = try await preferredRoot(after: candidate)
			}
		}
		return nil
	}

	/// The roots other apps show in windows that appeared since `before`.
	private func rootsOpened(elsewhere pid: Int32, since before: [UInt32: Int32]) async throws -> [Root] {
		let appeared = desktop.panelWindows().filter { before[$0.key] == nil && $0.value != pid }
		var roots: [Root] = []
		for owner in Set(appeared.values).sorted() {
			roots += try await self.roots(pid: owner).filter { $0.windowId.map { appeared[$0] != nil } ?? false }
		}
		return roots
	}

	/// What the actions did to the user's desktop: bcu's own activation and pointer, and a
	/// front app that changed while they ran, whoever changed it (a sheet can bring its app
	/// forward). Nothing is left unsaid, and nothing is said when nothing changed.
	private func foregroundEffects(activated: Bool, movedPointer: Bool, before: String?, after: String?) -> ForegroundEffects? {
		let changed = before != after
		guard activated || movedPointer || changed else { return nil }
		return ForegroundEffects(
			activated: activated ? true : nil,
			from: changed ? before : nil, to: changed || activated ? after : nil,
			pointer: movedPointer ? true : nil
		)
	}

	/// The array's own evidence, and the last step condition it met.
	private func recordedVerification(_ execution: Execution) -> Verification {
		guard let met = execution.verified else { return Verification(status: .none, evidence: execution.evidence) }
		return Verification(status: .verified, evidence: execution.evidence, text: trimmed(met.text), role: trimmed(met.role), value: trimmed(met.value), gone: met.gone == true ? true : nil, timeoutMs: waitTimeout(met.timeoutMs))
	}

	// MARK: delivery

	private func request(_ step: ResolvedStep, _ policy: ActPolicy) -> ActRequest {
		ActRequest(geometry: step.geometry, pid: step.root.pid, action: step.action, target: step.target, params: step.input.delivered(policy == .foreground ? .hid : .pid), policy: policy)
	}

	/// Strictly headless arrays of platform actions go as one platform batch. Otherwise each
	/// action climbs the ladder on its own, so a delivered background prefix is never replayed
	/// in the foreground; a step that names its element is found just before its turn. A root
	/// a step acts in must still be there when its turn comes; a root that closed is no reason
	/// to stop, and the steps after it go where they say.
	private func dispatch(_ transaction: Transaction, actions: [UiAction], headless: Bool, startsInForeground: Bool) async throws -> Execution {
		let target = transaction.target
		let count = actions.count
		let batch = transaction.steps.compactMap { planned -> ResolvedStep? in
			guard planned.expect == nil, case .deliver(let step) = planned.step, step.root.root.handle == target.root.handle else { return nil }
			return step
		}
		if headless && batch.count == transaction.steps.count { return try await deliverAsBatch(batch, count: count) }
		var done: [Execution] = []
		var trail = Trail(known: transaction.known)
		// What the steps delivered so far did to the desktop, for an error a later one ends in.
		var activated = false, movedPointer = false
		do {
			for (index, planned) in transaction.steps.enumerated() {
				var acted = target
				var result: Execution
				switch planned.step {
				case .wait(let ms):
					try await pause(.milliseconds(ms))
					result = Execution(waited: ())
				case .deliver(let step):
					acted = step.root
					if index > 0 { try await requireLive(step.root, index: index, count: count) }
					result = try await climb(step, headless: headless, startsInForeground: startsInForeground, rest: Array(actions[index...]), index: index, count: count)
				case .locate(let action, let locator):
					let step = try await locateStep(action, locator, index: index, count: count, base: target, trail: trail, headless: headless)
					acted = step.root
					result = try await climb(step, headless: headless, startsInForeground: startsInForeground, rest: Array(actions[index...]), index: index, count: count)
				}
				activated = activated || result.activated
				movedPointer = movedPointer || result.movedPointer
				trail.appeared.append(result.appeared)
				if result.outcome != .didnt, let expect = planned.expect {
					try await verifyStep(expect, index: index, count: count, acted: acted, base: target, closed: result.rootClosed, trail: trail)
					result.outcome = outcomeAfterCheck(result.outcome, .verified)
					result.verified = expect
				}
				done.append(result)
				if result.outcome == .didnt { break }
			}
		} catch var error as BCUError {
			if activated { error.foreground = ForegroundEffects(activated: true, pointer: error.foreground?.pointer) }
			if movedPointer { error.foreground = ForegroundEffects(activated: error.foreground?.activated, pointer: true) }
			throw error
		}
		return Execution(done)
	}

	/// The platform delivers the steps under one lock and looks at the roots once, after the
	/// last: an array of background accessibility actions then waits for the UI to settle once
	/// instead of once per step (measured: four setText steps take 0.5 s, against 1.9 s step by step).
	private func deliverAsBatch(_ steps: [ResolvedStep], count: Int) async throws -> Execution {
		let requests = steps.map { request($0, .axOnly) }
		let report = try await offload { [desktop = self.desktop] in try desktop.actBatch(requests) }
		guard !report.steps.isEmpty else { throw BCUError(.internalError, "The platform returned no checked steps for the transaction.") }
		if let stopped = report.stoppedAt, case .failed(let error) = report.steps[stopped] { throw stepFailure(error, index: stopped, count: count) }
		var execution = Execution(zip(report.steps, steps).compactMap { step, resolved in
			if case .completed(let result) = step { Execution(result, in: resolved, headless: true) } else { nil }
		})
		execution.outcome = report.outcome
		execution.settled = true
		execution.evidence = report.verification ?? execution.evidence
		let appeared = report.rootDelta.compactMap { if case .root(.appeared, let root) = $0 { root } else { nil } }
		if !appeared.isEmpty { execution.appeared = merged(appeared) }
		return execution
	}

	/// The ladder of docs/architecture.md: background first; the foreground only after a
	/// background rung proved it changed nothing (`didnt`) or refused as needing it, or
	/// when the caller asked to start there. A drag never climbs on its own: it would hold
	/// the real pointer and the user's front app for its whole path, so the caller is told how
	/// to ask for that instead. `rest` is the array from this step on, for that command.
	private func climb(_ step: ResolvedStep, headless: Bool, startsInForeground: Bool, rest: [UiAction], index: Int, count: Int) async throws -> Execution {
		func refusingTheForeground(_ reason: String) -> BCUError {
			let retry = (try? JSONCoding.string(rest)) ?? "[]"
			return stepFailure(BCUError(
				.actionFailed,
				"\(reason). A drag goes to the foreground only with --foreground, since it takes the user's front app and real pointer.",
				recovery: "Observe again with 'bcu observe-ui --root \(step.root.ref) --image always', then run it in the foreground on that stateId: bcu act-ui --state <stateId> --foreground '\(retry.replacingOccurrences(of: "'", with: "'\\''"))'"
			), index: index, count: count)
		}
		let climbs = step.action != .drag
		let foreground = request(step, .foreground)
		let first = request(step, headless ? .axOnly : .background)
		func inForeground() async throws -> Execution {
			do {
				return Execution(try await offload { [desktop = self.desktop] in try desktop.act(foreground) }, in: step, headless: headless)
			} catch let refusal as ForegroundRequired {
				throw BCUError(.actionFailed, refusal.message, foreground: refusal.foreground)
			}
		}
		if startsInForeground { return try await inForeground() }
		let report: ActionReport
		do {
			report = try await offload { [desktop = self.desktop] in try desktop.act(first) }
		} catch let refusal as ForegroundRequired {
			guard !headless else { throw BCUError(.actionFailed, refusal.message, foreground: refusal.foreground) }
			guard climbs else { throw refusingTheForeground(refusal.message) }
			try await ensureUnlocked()
			return try await inForeground()
		}
		if canRetryInForeground(report.outcome, headless: headless) {
			guard climbs else { throw refusingTheForeground("The drag was delivered in the background and changed nothing") }
			try await ensureUnlocked()
			return try await inForeground()
		}
		return Execution(report, in: step, headless: headless)
	}

	// MARK: postconditions

	/// Runs the expected condition; one that never holds fails the whole transaction.
	private func verify(_ expect: Expectation, transaction: Transaction, execution: inout Execution) async throws -> Verification {
		let text = trimmed(expect.text), role = trimmed(expect.role), value = trimmed(expect.value), scope = trimmed(expect.scope)
		let timeoutMs = waitTimeout(expect.timeoutMs)
		let gone = expect.gone == true
		let outline = Outline(restoring: transaction.outline)
		let searchRoot = try scope.map { try node($0, in: outline) } ?? outline.root
		let inScope = Set(searchRoot.subtree.map(ObjectIdentifier.init))
		let presentBefore = searchOutline(outline, text: text, role: role).contains { match in
			inScope.contains(ObjectIdentifier(match)) && (value == nil || normalized(match.value) == normalized(value))
		}
		guard try await conditionHolds(expect, in: transaction.target, scope: transaction.scope, timeoutMs: timeoutMs) else {
			execution.outcome = outcomeAfterCheck(execution.outcome, .failed)
			throw BCUError(.actionFailed, "The action was delivered but its postcondition was not satisfied within \(timeoutMs)ms\(scope.map { " inside \($0)" } ?? ""). Observe the root again before retrying.")
		}
		execution.outcome = outcomeAfterCheck(execution.outcome, .verified)
		return Verification(status: .verified, evidence: execution.evidence, text: text, role: role, value: value, scope: scope, gone: gone ? true : nil, timeoutMs: timeoutMs, preexisting: presentBefore != gone ? true : nil)
	}

	/// Only a proven no-op fails the transaction.
	private func failure(_ execution: Execution) -> BCUError {
		var unchanged = ""
		if let evidence = execution.evidence, let field = evidence.field, evidence.from == evidence.to {
			unchanged = " Its \(field.rawValue) stayed \(evidence.from.map { JSONValue.string($0).serialized() } ?? "undefined")."
		}
		let delivered = execution.delivery.map { " It was delivered via \($0)." } ?? ""
		return BCUError(.actionFailed, "The action did not produce the requested result.\(unchanged)\(delivered)")
	}

}

private extension ActionInput {
	func delivered(_ delivery: Delivery) -> ActionInput {
		ActionInput(button: button, clickCount: clickCount, scrollX: scrollX, scrollY: scrollY, path: path, text: text, keys: keys, pidDelivery: delivery == .pid)
	}
}
