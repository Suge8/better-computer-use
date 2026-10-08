/// Saved observations, keyed by the short stateId agents carry on every command.
import BCUCore
import os

/// What a state holds: one observation with its platform element handles. The handles live
/// only here, so evicting the state releases them.
public protocol StatePayload: Sendable {
	/// The size charged against the store's byte limits.
	var byteCount: Int { get }
}

public struct StoredState<Payload: StatePayload>: Sendable {
	public let stateId: String
	public let pid: Int
	/// The pid's epoch the observation was taken at; live work on it needs the pid still there.
	public let epoch: Int
	public let payload: Payload
}

public struct StateLimits: Sendable {
	public var maxEntries: Int
	public var maxBytes: Int
	public var maxRecordBytes: Int
	public var ttl: Duration

	public init(maxEntries: Int = 128, maxBytes: Int = 32 * 1024 * 1024, maxRecordBytes: Int = 4 * 1024 * 1024, ttl: Duration = .seconds(600)) {
		self.maxEntries = maxEntries
		self.maxBytes = maxBytes
		self.maxRecordBytes = maxRecordBytes
		self.ttl = ttl
	}
}

/// 32 random bits as 8 hex digits: short enough to carry on every command, and an id held
/// from before a restart matches a new state with odds of one in 2^32.
public func randomStateId() -> String {
	let value = String(UInt32.random(in: 0...UInt32.max), radix: 16)
	return String(repeating: "0", count: 8 - value.count) + value
}

/// Count-, byte-, record- and TTL-bounded, oldest evicted first.
public final class StateStore<Payload: StatePayload>: Sendable {
	private struct Entry: Sendable {
		let state: StoredState<Payload>
		let storedAt: ContinuousClock.Instant
	}

	private struct Contents: Sendable {
		var entries: [Entry] = []
		var bytes = 0

		mutating func remove(at index: Int) {
			bytes -= entries[index].state.payload.byteCount
			entries.remove(at: index)
		}
	}

	private let limits: StateLimits
	private let now: @Sendable () -> ContinuousClock.Instant
	private let randomId: @Sendable () -> String
	private let contents = OSAllocatedUnfairLock(initialState: Contents())

	public init(limits: StateLimits = StateLimits(), now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, randomId: @escaping @Sendable () -> String = randomStateId) {
		self.limits = limits
		self.now = now
		self.randomId = randomId
	}

	/// Saves an observation under a fresh stateId no live state holds.
	public func insert(pid: Int, epoch: Int, payload: Payload) throws -> StoredState<Payload> {
		let bytes = payload.byteCount
		guard bytes <= min(limits.maxRecordBytes, limits.maxBytes) else {
			throw BCUError(.stateTooLarge, "The observation is \(bytes) bytes, above the \(min(limits.maxRecordBytes, limits.maxBytes))-byte capacity of one state.")
		}
		let storedAt = now()
		return contents.withLock { contents in
			contents.entries.removeAll { storedAt - $0.storedAt >= limits.ttl }
			contents.bytes = contents.entries.reduce(0) { $0 + $1.state.payload.byteCount }
			var stateId = randomId()
			while contents.entries.contains(where: { $0.state.stateId == stateId }) { stateId = randomId() }
			let state = StoredState(stateId: stateId, pid: pid, epoch: epoch, payload: payload)
			contents.entries.append(Entry(state: state, storedAt: storedAt))
			contents.bytes += bytes
			while contents.entries.count > limits.maxEntries || contents.bytes > limits.maxBytes { contents.remove(at: 0) }
			return state
		}
	}

	public func get(_ stateId: String) -> StoredState<Payload>? {
		let at = now()
		return contents.withLock { contents in
			guard let index = contents.entries.firstIndex(where: { $0.state.stateId == stateId }) else { return nil }
			if at - contents.entries[index].storedAt >= limits.ttl {
				contents.remove(at: index)
				return nil
			}
			return contents.entries[index].state
		}
	}

	/// The most recently saved live state of `pid` whose observation `matches`.
	public func latest(pid: Int, where matches: @Sendable (Payload) -> Bool) -> StoredState<Payload>? {
		let at = now()
		return contents.withLock { contents in
			contents.entries.last { at - $0.storedAt < limits.ttl && $0.state.pid == pid && matches($0.state.payload) }?.state
		}
	}

	public var count: Int { contents.withLock { $0.entries.count } }

	public var byteCount: Int { contents.withLock { $0.bytes } }

	public func removeAll() {
		contents.withLock { $0 = Contents() }
	}
}
