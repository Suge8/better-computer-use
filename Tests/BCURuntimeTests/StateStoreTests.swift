import BCUCore
import Foundation
import os
import Testing
@testable import BCURuntime

/// Stands in for an observation that owns platform element handles; its deinit is the moment
/// those handles would be released.
final class FakeObservation: StatePayload {
	let name: String
	let byteCount: Int
	private let released: Log?

	init(_ name: String, bytes: Int = 100, released: Log? = nil) {
		self.name = name
		self.byteCount = bytes
		self.released = released
	}

	deinit { released?.append(name) }
}

final class ManualClock: Sendable {
	private let offset = OSAllocatedUnfairLock<Duration>(initialState: .zero)
	private let origin = ContinuousClock.now

	func advance(_ duration: Duration) { offset.withLock { $0 += duration } }

	var now: ContinuousClock.Instant { origin + offset.withLock { $0 } }
}

@Suite struct StateStoreTests {
	@Test func stateIdsAreEightHexDigits() throws {
		let store = StateStore<FakeObservation>()
		let id = try store.insert(pid: 1, epoch: 0, payload: FakeObservation("a")).stateId
		#expect(id.count == 8)
		#expect(id.allSatisfy { "0123456789abcdef".contains($0) })
	}

	@Test func clashingIdIsRedrawn() throws {
		let draws = OSAllocatedUnfairLock(initialState: ["aaaaaaaa", "aaaaaaaa", "bbbbbbbb"])
		let store = StateStore<FakeObservation>(randomId: { draws.withLock { $0.removeFirst() } })
		#expect(try store.insert(pid: 1, epoch: 0, payload: FakeObservation("a")).stateId == "aaaaaaaa")
		#expect(try store.insert(pid: 1, epoch: 0, payload: FakeObservation("b")).stateId == "bbbbbbbb")
		#expect(store.get("aaaaaaaa")?.payload.name == "a")
	}

	@Test func recordLimitEvictsTheOldest() throws {
		let store = StateStore<FakeObservation>(limits: StateLimits(maxEntries: 2))
		let first = try store.insert(pid: 1, epoch: 0, payload: FakeObservation("a"))
		let second = try store.insert(pid: 1, epoch: 0, payload: FakeObservation("b"))
		let third = try store.insert(pid: 1, epoch: 0, payload: FakeObservation("c"))
		#expect(store.get(first.stateId) == nil)
		#expect(store.get(second.stateId)?.payload.name == "b")
		#expect(store.get(third.stateId)?.payload.name == "c")
	}

	@Test func byteLimitEvictsTheOldest() throws {
		let store = StateStore<FakeObservation>(limits: StateLimits(maxBytes: 250, maxRecordBytes: 200))
		let first = try store.insert(pid: 1, epoch: 0, payload: FakeObservation("a", bytes: 100))
		let second = try store.insert(pid: 1, epoch: 0, payload: FakeObservation("b", bytes: 100))
		_ = try store.insert(pid: 1, epoch: 0, payload: FakeObservation("c", bytes: 100))
		#expect(store.get(first.stateId) == nil)
		#expect(store.get(second.stateId) != nil)
		#expect(store.byteCount == 200)
	}

	@Test func oversizedStateIsRejectedNotTruncated() throws {
		let store = StateStore<FakeObservation>(limits: StateLimits(maxRecordBytes: 100))
		let kept = try store.insert(pid: 1, epoch: 0, payload: FakeObservation("a", bytes: 100))
		let error = #expect(throws: BCUError.self) {
			try store.insert(pid: 1, epoch: 0, payload: FakeObservation("b", bytes: 101))
		}
		#expect(error?.code == .stateTooLarge)
		#expect(store.count == 1)
		#expect(store.get(kept.stateId) != nil)
	}

	@Test func stateExpiresAfterItsTTL() throws {
		let clock = ManualClock()
		let store = StateStore<FakeObservation>(limits: StateLimits(ttl: .seconds(600)), now: { clock.now })
		let state = try store.insert(pid: 1, epoch: 0, payload: FakeObservation("a"))
		clock.advance(.seconds(599))
		#expect(store.get(state.stateId) != nil)
		clock.advance(.seconds(1))
		#expect(store.get(state.stateId) == nil)
	}

	@Test func evictionReleasesTheStatesElementHandles() throws {
		let released = Log()
		let store = StateStore<FakeObservation>(limits: StateLimits(maxEntries: 1))
		_ = try store.insert(pid: 1, epoch: 0, payload: FakeObservation("old", released: released))
		_ = try store.insert(pid: 1, epoch: 0, payload: FakeObservation("new", released: released))
		#expect(released.all == ["old"])
	}
}
