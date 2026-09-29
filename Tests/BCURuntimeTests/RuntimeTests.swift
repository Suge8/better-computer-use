import BCUCore
import Foundation
import Testing
@testable import BCURuntime

/// Per-pid ordering and stale-state judgement around observe, live reads and act.
@Suite(.timeLimit(.minutes(1)))
struct RuntimeTests {
	private func observed(_ runtime: Runtime<FakeObservation>, pid: Int = 7, _ name: String = "base") async throws -> StoredState<FakeObservation> {
		try await runtime.observe(pid: pid) { _ in FakeObservation(name) }
	}

	@Test func unknownStateIsStale() async throws {
		let runtime = Runtime<FakeObservation>()
		let error = #expect(throws: BCUError.self) { try runtime.state("deadbeef") }
		#expect(error?.code == .staleState)
	}

	@Test func actSavesASuccessorAndStalesItsBase() async throws {
		let runtime = Runtime<FakeObservation>()
		let base = try await observed(runtime)
		let successor = try await runtime.act(from: base.stateId, prepare: { _ in "click" }) { _, lane in
			try lane.save(FakeObservation("after")).stateId
		}
		#expect(try runtime.state(successor).payload.name == "after")
		let error = await #expect(throws: BCUError.self) {
			try await runtime.act(from: base.stateId, prepare: { _ in "click" }) { _, _ in }
		}
		#expect(error?.code == .staleState)
		// Cached queries still read the base state; only live work on it is stale.
		#expect(try runtime.state(base.stateId).payload.name == "base")
	}

	@Test func rejectedActDoesNotAdvanceTheEpoch() async throws {
		let runtime = Runtime<FakeObservation>()
		let base = try await observed(runtime)
		await #expect(throws: BCUError.self) {
			try await runtime.act(from: base.stateId, prepare: { _ -> String in throw BCUError(.invalidArguments, "bad action") }) { _, _ in }
		}
		let delivered = Counter()
		try await runtime.act(from: base.stateId, prepare: { _ in "click" }) { _, _ in delivered.increment() }
		#expect(delivered.current == 1)
	}

	@Test func failureAfterDeliveryStartedStillStalesTheBase() async throws {
		let runtime = Runtime<FakeObservation>()
		let base = try await observed(runtime)
		await #expect(throws: BCUError.self) {
			try await runtime.act(from: base.stateId, prepare: { _ in "click" }) { _, _ in throw BCUError(.actionFailed, "partial") }
		}
		let error = await #expect(throws: BCUError.self) {
			try await runtime.act(from: base.stateId, prepare: { _ in "click" }) { _, _ in }
		}
		#expect(error?.code == .staleState)
	}

	@Test func concurrentActsFromOneStateDeliverOnce() async throws {
		let runtime = Runtime<FakeObservation>()
		let base = try await observed(runtime)
		let delivered = Counter()
		let outcomes = await withTaskGroup(of: ErrorCode?.self) { group in
			for _ in 0..<2 {
				group.addTask {
					do {
						try await runtime.act(from: base.stateId, prepare: { _ in "click" }) { _, _ in delivered.increment() }
						return nil
					} catch {
						return (error as? BCUError)?.code
					}
				}
			}
			return await group.reduce(into: [ErrorCode?]()) { $0.append($1) }
		}
		#expect(delivered.current == 1)
		#expect(outcomes.filter { $0 == nil }.count == 1)
		#expect(outcomes.contains(.staleState))
	}

	@Test func liveReadOfAStaleStateIsRefused() async throws {
		let runtime = Runtime<FakeObservation>()
		let base = try await observed(runtime)
		let fresh = try await runtime.read(from: base.stateId) { _, lane in try lane.save(FakeObservation("waited")).stateId }
		try await runtime.act(from: fresh, prepare: { _ in "click" }) { _, _ in }
		let error = await #expect(throws: BCUError.self) {
			try await runtime.read(from: base.stateId) { _, _ in }
		}
		#expect(error?.code == .staleState)
	}

	@Test func onePidRunsInOrder() async throws {
		let runtime = Runtime<FakeObservation>()
		let log = Log()
		let gate = Gate()
		let started = Gate()
		let first = Task {
			try await runtime.observe(pid: 7) { _ in
				started.open()
				await gate.wait()
				log.append("first done")
				return FakeObservation("first")
			}
		}
		await started.wait()
		let second = Task {
			try await runtime.observe(pid: 7) { _ in
				log.append("second start")
				return FakeObservation("second")
			}
		}
		try await Task.sleep(for: .milliseconds(100))
		gate.open()
		_ = try await (first.value, second.value)
		#expect(log.all == ["first done", "second start"])
	}

	@Test func differentPidsRunInParallel() async throws {
		let runtime = Runtime<FakeObservation>()
		let gate = Gate()
		// The first pid's work only finishes once the second pid's work has run.
		async let first = runtime.observe(pid: 7) { _ in
			await gate.wait()
			return FakeObservation("seven")
		}
		async let second = runtime.observe(pid: 8) { _ in
			gate.open()
			return FakeObservation("eight")
		}
		let names = try await [first.payload.name, second.payload.name]
		#expect(names == ["seven", "eight"])
	}

	@Test func closedRuntimeRefusesNewWork() async throws {
		let runtime = Runtime<FakeObservation>()
		await runtime.close()
		let error = await #expect(throws: BCUError.self) { try await observed(runtime) }
		#expect(error?.code == .residentUnavailable)
	}
}
