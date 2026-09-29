import BCUCore
import Foundation
import Testing
@testable import BCURuntime

private let noHandler: RequestHandler = { _ in .null }

/// Starting, finding and stopping the resident process.
@Suite(.timeLimit(.minutes(1)))
struct LifecycleTests {
	@Test func concurrentClientsStartOneResident() async throws {
		let path = temporarySocketPath()
		let launches = Counter()
		let servers = Log()
		let launcher: Launcher = {
			launches.increment()
			// Like `open -g bcu.app --args serve`: the launch returns before the resident listens.
			Task.detached {
				do {
					if try Server(socketPath: path, handler: noHandler).start() { servers.append(path) }
				} catch {
					Issue.record(error)
				}
			}
		}
		let pids = try await withThrowingTaskGroup(of: Int.self) { group in
			for _ in 0..<8 {
				group.addTask {
					try await blocking {
						let connection = try Client.connectOrStart(socketPath: path, launcher: launcher)
						defer { connection.close() }
						return connection.status.pid
					}
				}
			}
			return try await group.reduce(into: [Int]()) { $0.append($1) }
		}
		#expect(launches.current == 1)
		#expect(servers.all.count == 1)
		#expect(Set(pids) == [Int(getpid())])
		#expect(try await blocking { try Client.stop(socketPath: path) } != nil)
	}

	@Test func staleSocketFileIsReplaced() async throws {
		let path = temporarySocketPath()
		try leaveStaleSocket(at: path)
		let launches = Counter()
		let status = try await blocking {
			let connection = try Client.connectOrStart(socketPath: path) {
				launches.increment()
				Task.detached { #expect(throws: Never.self) { try Server(socketPath: path, handler: noHandler).start() } }
			}
			defer { connection.close() }
			return connection.status
		}
		#expect(launches.current == 1)
		#expect(status.protocolVersion == wireProtocolVersion)
		_ = try await blocking { try Client.stop(socketPath: path) }
	}

	@Test func launcherFailureIsReported() async throws {
		let path = temporarySocketPath()
		let error = await #expect(throws: BCUError.self) {
			try await blocking {
				_ = try Client.connectOrStart(socketPath: path) { throw BCUError(.internalError, "open failed") }
			}
		}
		#expect(error?.code == .residentUnavailable)
		#expect(error?.message.contains("open failed") == true)
	}

	@Test func residentThatNeverListensTimesOut() async throws {
		let path = temporarySocketPath()
		let error = await #expect(throws: BCUError.self) {
			try await blocking {
				_ = try Client.connectOrStart(socketPath: path, readyTimeout: .milliseconds(200)) {}
			}
		}
		#expect(error?.code == .residentUnavailable)
	}

	@Test func statusAndStopDoNotStartAResident() async throws {
		let path = temporarySocketPath()
		#expect(try await blocking { try Client.connectIfRunning(socketPath: path) == nil })
		#expect(try await blocking { try Client.stop(socketPath: path) } == nil)
		#expect(!FileManager.default.fileExists(atPath: path))
	}

	@Test func stopEndsTheRunningResident() async throws {
		let path = temporarySocketPath()
		let server = Server(socketPath: path, handler: noHandler)
		#expect(try server.start())
		let status = try await blocking { try Client.stop(socketPath: path) }
		#expect(status == ResidentStatus(pid: Int(getpid()), protocolVersion: wireProtocolVersion))
		await server.stopped()
		#expect(!FileManager.default.fileExists(atPath: path))
		#expect(try await blocking { try Client.connectIfRunning(socketPath: path) == nil })
	}

	@Test func secondResidentDefersToTheRunningOne() async throws {
		let path = temporarySocketPath()
		let first = Server(socketPath: path, handler: noHandler)
		#expect(try first.start())
		defer { first.stop() }
		#expect(try Server(socketPath: path, handler: noHandler).start() == false)
		#expect(try await blocking { try Client.connectIfRunning(socketPath: path)?.status.pid } == Int(getpid()))
	}

	@Test func idleResidentExits() async throws {
		let path = temporarySocketPath()
		let server = Server(socketPath: path, idleTimeout: .milliseconds(100), handler: noHandler)
		#expect(try server.start())
		await server.stopped()
		#expect(!FileManager.default.fileExists(atPath: path))
	}

	@Test func requestInFlightKeepsTheResidentAlive() async throws {
		let path = temporarySocketPath()
		let gate = Gate()
		let started = Gate()
		let server = Server(socketPath: path, idleTimeout: .milliseconds(100)) { _ in
			started.open()
			await gate.wait()
			return .string("done")
		}
		#expect(try server.start())
		let reply = Task {
			try await blocking {
				let connection = try #require(try Client.connectIfRunning(socketPath: path))
				defer { connection.close() }
				return try connection.send(.plain(.doctor))
			}
		}
		await started.wait()
		try await Task.sleep(for: .milliseconds(400))
		#expect(FileManager.default.fileExists(atPath: path))
		gate.open()
		#expect(try await reply.value == .string("done"))
		await server.stopped()
	}
}
