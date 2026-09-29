/// Live work per resource: each pid is a lane whose work runs one at a time while other pids
/// run in parallel, and whose epoch moves when an action is delivered to it. A state is live
/// while its pid's epoch is the one it was observed at; cached queries read saved states and
/// never enter a lane.
import BCUCore

/// The lane a piece of live work runs in, at the epoch it runs at.
public struct Lane<Payload: StatePayload>: Sendable {
	public let pid: Int
	public let epoch: Int
	fileprivate let states: StateStore<Payload>

	/// Saves an observation taken in this lane as a live state.
	public func save(_ payload: Payload) throws -> StoredState<Payload> {
		try states.insert(pid: pid, epoch: epoch, payload: payload)
	}
}

public actor Runtime<Payload: StatePayload> {
	private struct LaneRecord {
		var epoch = 0
		var tail: Task<Void, Never>?
	}

	public nonisolated let states: StateStore<Payload>
	private var lanes: [Int: LaneRecord] = [:]
	private var closed = false

	public init(states: StateStore<Payload> = StateStore()) {
		self.states = states
	}

	/// A saved state for cached queries.
	public nonisolated func state(_ stateId: String) throws -> StoredState<Payload> {
		guard let state = states.get(stateId) else {
			throw BCUError(.staleState, "State '\(stateId)' is unavailable or was evicted. Observe the root again.")
		}
		return state
	}

	/// Captures a new observation in the pid's lane and saves it at the lane's epoch.
	public func observe(pid: Int, _ capture: @escaping @Sendable (Int) async throws -> Payload) async throws -> StoredState<Payload> {
		try await enqueue(pid) {
			let lane = await self.lane(pid)
			return try lane.save(try await capture(lane.epoch))
		}
	}

	/// Live work against a state that must still be current, such as waiting for a condition;
	/// it leaves the epoch alone.
	public func read<T: Sendable>(from stateId: String, _ work: @escaping @Sendable (StoredState<Payload>, Lane<Payload>) async throws -> T) async throws -> T {
		let state = try state(stateId)
		return try await enqueue(state.pid) {
			try await work(state, try await self.current(state))
		}
	}

	/// An action from a current state. `prepare` checks and resolves it and may refuse it; only
	/// once it has passed does the epoch move, before `deliver` runs, so a delivery that fails
	/// or leaves an uncertain effect still stales every state observed before it.
	@discardableResult
	public func act<Prepared: Sendable, T: Sendable>(from stateId: String, prepare: @escaping @Sendable (StoredState<Payload>) async throws -> Prepared, deliver: @escaping @Sendable (Prepared, Lane<Payload>) async throws -> T) async throws -> T {
		let state = try state(stateId)
		return try await enqueue(state.pid) {
			_ = try await self.current(state)
			let prepared = try await prepare(state)
			return try await deliver(prepared, await self.advance(state.pid))
		}
	}

	/// Refuses new work and waits for the work already queued.
	public func close() async {
		closed = true
		for record in lanes.values { await record.tail?.value }
	}

	private func lane(_ pid: Int) -> Lane<Payload> {
		Lane(pid: pid, epoch: lanes[pid, default: LaneRecord()].epoch, states: states)
	}

	private func current(_ state: StoredState<Payload>) throws -> Lane<Payload> {
		let lane = lane(state.pid)
		guard lane.epoch == state.epoch else {
			throw BCUError(.staleState, "State '\(state.stateId)' was observed before a later action on this app. Observe the root again.")
		}
		return lane
	}

	private func advance(_ pid: Int) -> Lane<Payload> {
		lanes[pid, default: LaneRecord()].epoch += 1
		return lane(pid)
	}

	private func enqueue<T: Sendable>(_ pid: Int, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
		guard !closed else { throw BCUError(.residentUnavailable, "The bcu resident process is shutting down. Retry the command.") }
		let previous = lanes[pid]?.tail
		let task = Task {
			await previous?.value
			return try await work()
		}
		lanes[pid, default: LaneRecord()].tail = Task { _ = await task.result }
		return try await task.value
	}
}
