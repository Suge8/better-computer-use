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

/// One action ready to deliver: a pause, or a platform request whose policy the ladder picks.
private enum Step: Sendable {
	case wait(ms: Int)
	case deliver(action: ActAction, target: ActTarget, input: ActionInput)
}

/// Everything checked before the epoch moves: the transaction is refused, not half delivered,
/// when any of it fails.
private struct Transaction: Sendable {
	let target: Target
	let steps: [Step]
	let scope: Handle?
	let base: Observation
	var outline: SerializedOutline { base.outline.current.outline }
}

/// What happened while the actions were delivered.
private struct Execution {
	var outcome: ActOutcome
	var evidence: BCUCore.ActEvidence?
	var appeared: [Root] = []
	/// How the last step was delivered: `ax`, `pid` or `hid`.
	var delivery: String?
	/// The platform already waited for the UI to settle.
	var settled = false
	/// Every step went through background accessibility.
	var quiet: Bool
	var openedMenus = false
	var actionCount: Int
	var rootClosed = false
	var skipped = 0

	/// One array: the worst outcome, the last evidence, every root opened.
	init(_ steps: [Execution]) {
		let outcomes = steps.map(\.outcome)
		outcome = outcomes.contains(.didnt) ? .didnt : outcomes.contains(.unknown) ? .unknown : .worked
		evidence = steps.last { $0.evidence != nil }?.evidence
		appeared = merged(steps.flatMap(\.appeared))
		delivery = steps.last?.delivery
		quiet = steps.allSatisfy(\.quiet)
		openedMenus = steps.contains(where: \.openedMenus)
		actionCount = steps.count
	}

	/// One step, as the platform reported it.
	init(_ report: ActionReport, closedOut target: Target, headless: Bool) {
		outcome = report.outcome
		evidence = report.verification
		appeared = report.rootDelta.compactMap { if case .root(.appeared, let root) = $0 { root } else { nil } }
		delivery = report.performed.delivery.rawValue
		settled = report.performed.deltaSource != nil
		quiet = headless || report.performed.delivery == .ax
		openedMenus = report.performed.openedMenus
		actionCount = 1
		rootClosed = report.rootDelta.contains { if case .root(.closed, let root) = $0 { root.handle == target.root.handle } else { false } }
	}

	init(waited: Void) {
		outcome = .worked
		quiet = true
		actionCount = 1
	}

	init(failed: Void) {
		outcome = .didnt
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

extension Daemon {
	func act(_ params: ActParams) async throws -> BCUCore.ActResult {
		let actions = try validateActions(params.actions.map { try JSONCoding.encode($0) })
		let headless = params.headless ?? false
		let foreground = params.foreground ?? false
		if headless && foreground {
			throw BCUError(.invalidArguments, "--foreground contradicts headless, which forbids activating the app.")
		}
		let image = params.image ?? .never
		if let expect = params.expect, trimmed(expect.text) == nil, trimmed(expect.role) == nil, trimmed(expect.value) == nil {
			throw BCUError(.invalidArguments, "act-ui expectations require --expect-text, --expect-role, or --expect-value.")
		}
		return try await runtime.act(from: params.stateId, prepare: { state in
			try await self.prepare(actions, params: params, headless: headless, state: state)
		}, deliver: { transaction, lane in
			try await self.deliver(transaction, actions: actions, params: params, headless: headless, image: image, lane: lane)
		})
	}

	private func prepare(_ actions: [UiAction], params: ActParams, headless: Bool, state: StoredState<Observation>) async throws -> Transaction {
		let observation = state.payload
		let outline = observation.outline.outline()
		// Scope refs belong to the base state, so they are resolved before the UI moves.
		let scope = try trimmed(params.expect?.scope).map { try observation.outline.handle(of: try node($0, in: outline)) }
		let target = try await current(observation.target)
		let environment = ActionEnvironment(outline: outline, image: observation.image, headless: headless)
		var focus = ActionState(currentFocus: false)
		var steps: [Step] = []
		for action in actions {
			let prepared = try prepareAction(action, state: focus, environment: environment)
			if prepared.establishesFocus { focus.currentFocus = true }
			steps.append(try step(prepared, outline: outline, observation: observation))
		}
		return Transaction(target: target, steps: steps, scope: scope, base: observation)
	}

	private func step(_ prepared: PreparedAction, outline: Outline, observation: Observation) throws -> Step {
		if case .wait(let ms) = prepared.params { return .wait(ms: ms) }
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
		var input = ActionInput(preserveFocus: preserveFocus)
		switch prepared.params {
		case .click(let button, let clickCount):
			input = ActionInput(button: button == .right ? .right : button == .middle ? .center : .left, clickCount: clickCount, preserveFocus: preserveFocus)
		case .text(let text): input = ActionInput(text: text, preserveFocus: preserveFocus)
		case .keys(let keys): input = ActionInput(keys: keys, preserveFocus: preserveFocus)
		case .scroll(let x, let y): input = ActionInput(scrollX: x, scrollY: y, preserveFocus: preserveFocus)
		case .drag(let path): input = ActionInput(path: path.map { CGPoint(x: $0.x, y: $0.y) }, preserveFocus: preserveFocus)
		case .none, .wait: break
		}
		guard let action = ActAction(rawValue: prepared.action.rawValue) else {
			throw BCUError(.invalidArguments, "Action \(prepared.action.rawValue) cannot be delivered.")
		}
		return .deliver(action: action, target: target, input: input)
	}

	private func deliver(_ transaction: Transaction, actions: [UiAction], params: ActParams, headless: Bool, image: ImageMode, lane: Lane<Observation>) async throws -> BCUCore.ActResult {
		let target = transaction.target
		var execution = try await dispatch(transaction, count: actions.count, geometry: transaction.base.geometry, headless: headless, startsInForeground: params.foreground ?? false)
		if execution.rootClosed { return try await closedRoot(execution, target: target, params: params, image: image, lane: lane) }
		let executed = Array(actions.prefix(execution.actionCount))
		var verification = Verification(status: .none, evidence: execution.evidence)
		if let expect = params.expect {
			do {
				verification = try await verify(expect, transaction: transaction, execution: &execution)
			} catch {
				if try await isLive(target) { throw error }
				execution.rootClosed = true
			}
		} else if !execution.settled {
			try await pause(execution.quiet ? settleAfterAccessibility : settleAfterRawInput)
		}
		var successor: (observation: Observation, image: LookImage?)?
		if !execution.rootClosed {
			do {
				successor = try await capture(target, image: image, base: transaction.base)
			} catch {
				if try await isLive(target) { throw error }
			}
		}
		guard let successor else { return try await closedRoot(execution, target: target, params: params, image: image, lane: lane) }
		let saved = try lane.save(successor.observation)
		let next = saved.payload.outline.outline()
		let outcome = outcomeAfterObservedValues(execution.outcome, actions: executed) { next.node($0)?.value }
		if outcome == .didnt { throw failure(execution) }
		let view = successorView(base: Outline(restoring: transaction.outline), next: next, menusOpenedByBcu: execution.openedMenus)
		let roots = execution.appeared.compactMap(appearance)
		return BCUCore.ActResult(
			stateId: saved.stateId, baseStateId: params.stateId, outcome: outcome, verification: verification,
			delivery: execution.delivery ?? Delivery.ax.rawValue, roots: roots.isEmpty ? nil : roots,
			changes: view.changes, offscreen: view.offscreen, nodes: view.nodes, shown: view.shown, total: view.total,
			image: try await artifact(successor.image, for: saved.stateId)
		)
	}

	// MARK: delivery

	/// Strictly headless arrays of platform actions go as one platform batch. Otherwise each
	/// action climbs the ladder on its own, so a delivered background prefix is never replayed
	/// in the foreground.
	private func dispatch(_ transaction: Transaction, count: Int, geometry: LookGeometry, headless: Bool, startsInForeground: Bool) async throws -> Execution {
		let target = transaction.target
		func request(_ action: ActAction, _ actTarget: ActTarget, _ input: ActionInput, _ policy: ActPolicy) -> ActRequest {
			ActRequest(geometry: geometry, pid: target.pid, action: action, target: actTarget, params: input.delivered(policy == .foreground ? .hid : .pid), policy: policy)
		}
		let deliveries = transaction.steps.compactMap { step -> ActRequest? in
			guard case .deliver(let action, let actTarget, let input) = step else { return nil }
			return request(action, actTarget, input, .axOnly)
		}
		if headless && deliveries.count == transaction.steps.count {
			let report = try await offload { [desktop = self.desktop] in try desktop.actBatch(deliveries) }
			guard !report.steps.isEmpty else { throw BCUError(.internalError, "The platform returned no checked steps for the transaction.") }
			var execution = Execution(report.steps.map { step in
				switch step {
				case .completed(let result): Execution(result, closedOut: target, headless: true)
				case .failed: Execution(failed: ())
				}
			})
			execution.outcome = report.outcome
			execution.settled = true
			execution.evidence = report.verification ?? execution.evidence
			let appeared = report.rootDelta.compactMap { if case .root(.appeared, let root) = $0 { root } else { nil } }
			if !appeared.isEmpty { execution.appeared = merged(appeared) }
			let closed = report.rootDelta.contains { if case .root(.closed, let root) = $0 { root.handle == target.root.handle } else { false } }
			if closed {
				// The step that failed on the closed root was never delivered to it.
				let failedAt = report.stoppedAt.flatMap { if case .failed = report.steps[$0] { $0 } else { nil } }
				execution.rootClosed = true
				execution.skipped = count - (failedAt ?? report.steps.count)
			}
			return execution
		}
		var done: [Execution] = []
		var rootClosed = false
		for (index, step) in transaction.steps.enumerated() {
			let result: Execution
			do {
				switch step {
				case .wait(let ms):
					try await pause(.milliseconds(ms))
					result = Execution(waited: ())
				case .deliver(let action, let actTarget, let input):
					result = try await climb { policy in request(action, actTarget, input, policy) }
				}
			} catch {
				// The platform saw no closure, but an earlier step may still have closed the root.
				if index > 0, try await !isLive(target) {
					rootClosed = true
					break
				}
				throw error
			}
			done.append(result)
			if result.outcome == .didnt { break }
			if result.rootClosed {
				rootClosed = true
				break
			}
		}
		var execution = Execution(done)
		if rootClosed {
			execution.rootClosed = true
			execution.skipped = count - done.count
		}
		return execution

		/// The ladder of docs/architecture.md: background first; the foreground only after a
		/// background rung proved it changed nothing (`didnt`) or refused as needing it, or
		/// when the caller asked to start there.
		func climb(_ request: (ActPolicy) -> ActRequest) async throws -> Execution {
			let foreground = request(.foreground)
			let first = request(headless ? .axOnly : .background)
			func inForeground() async throws -> Execution {
				do {
					return Execution(try await offload { [desktop = self.desktop] in try desktop.act(foreground) }, closedOut: target, headless: headless)
				} catch let refusal as ForegroundRequired {
					throw BCUError(.actionFailed, refusal.message)
				}
			}
			if startsInForeground { return try await inForeground() }
			let report: ActionReport
			do {
				report = try await offload { [desktop = self.desktop] in try desktop.act(first) }
			} catch let refusal as ForegroundRequired {
				guard !headless else { throw BCUError(.actionFailed, refusal.message) }
				return try await inForeground()
			}
			if canRetryInForeground(report.outcome, headless: headless) { return try await inForeground() }
			return Execution(report, closedOut: target, headless: headless)
		}
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
		let target = transaction.target
		let request = WaitForRequest(pid: target.pid, root: target.root.handle, role: role, text: text, value: value, gone: gone, scope: transaction.scope, timeoutMs: timeoutMs)
		let outcome = try await offload { [desktop = self.desktop] in try desktop.waitFor(request) }
		guard outcome == .found || outcome == .gone else {
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

	// MARK: a closed root

	/// The actions closed the root they ran in — a sheet's button, a dialog's OK. That is the
	/// proof they landed, and the successor observes the root the app now shows instead.
	private func closedRoot(_ execution: Execution, target: Target, params: ActParams, image: ImageMode, lane: Lane<Observation>) async throws -> BCUCore.ActResult {
		let closedEvidence = BCUCore.ActEvidence(source: .root, field: .closed)
		let verification: Verification
		switch params.expect {
		case nil: verification = Verification(status: .none, evidence: closedEvidence)
		case let expect? where expect.gone == true: verification = Verification(status: .verified, evidence: closedEvidence, scope: trimmed(expect.scope), gone: true)
		case _?:
			let delivered = execution.delivery.map { " It was delivered via \($0)." } ?? ""
			throw BCUError(.actionFailed, "The root the action ran in closed, so its postcondition could not be checked.\(delivered)")
		}
		let next = try await preferredRoot(after: target)
		var saved: StoredState<Observation>?
		var picture: LookImage?
		if let next {
			let captured = try await capture(next, image: image)
			saved = try lane.save(captured.observation)
			picture = captured.image
		}
		let view = saved.map { fullView($0.payload.outline.outline()) }
		let roots = execution.appeared.compactMap(appearance)
		let artifact = if let saved { try await artifact(picture, for: saved.stateId) } else { ImageInfo?.none }
		return BCUCore.ActResult(
			stateId: saved?.stateId, baseStateId: params.stateId, outcome: .worked, verification: verification,
			delivery: execution.delivery ?? Delivery.ax.rawValue, roots: roots.isEmpty ? nil : roots,
			closed: ClosedRoot(root: target.appearance, skipped: execution.skipped > 0 ? execution.skipped : nil),
			next: next?.appearance, changes: view?.changes, offscreen: view?.offscreen, nodes: view?.nodes, shown: view?.shown, total: view?.total,
			image: artifact
		)
	}
}

private extension ActionInput {
	func delivered(_ delivery: Delivery) -> ActionInput {
		ActionInput(button: button, clickCount: clickCount, scrollX: scrollX, scrollY: scrollY, path: path, text: text, keys: keys, preserveFocus: preserveFocus, pidDelivery: delivery == .pid)
	}
}
