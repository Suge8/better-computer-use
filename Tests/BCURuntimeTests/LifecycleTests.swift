import BCUCore
import Foundation
import BCUTestSupport
import Testing
@testable import BCURuntime

private let noHandler: RequestHandler = { _ in .null }

/// Starting, finding and stopping the resident process.
@Suite(.timeLimit(.minutes(1)), .temporaryRoot)
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

	/// The idle timer starts with the resident, so on a loaded runner it can fire before the
	/// client arrives; that attempt never had a request in flight and says nothing about one. A
	/// client whose handshake got an answer was accepted, which cancelled the timer, so every
	/// attempt that connects ends the same way and only it is judged.
	@Test func requestInFlightKeepsTheResidentAlive() async throws {
		let idle = Duration.milliseconds(100)
		for _ in 0..<5 {
			let path = temporarySocketPath()
			let gate = Gate()
			let started = Gate()
			let connected = Gate()
			let connections = Counter()
			let server = Server(socketPath: path, idleTimeout: idle) { _ in
				started.open()
				await gate.wait()
				return .string("done")
			}
			#expect(try server.start())
			let reply = Task {
				try await blocking { () throws -> JSONValue? in
					let attempt = try? Client.connectIfRunning(socketPath: path)
					guard let connection = attempt ?? nil else {
						connected.open()
						return nil
					}
					defer { connection.close() }
					connections.increment()
					connected.open()
					return try connection.send(.plain(.doctor))
				}
			}
			await connected.wait()
			guard connections.current == 1 else {
				await server.stopped()
				continue
			}
			await started.wait()
			// Several idle periods pass with the request still unanswered.
			try await Task.sleep(for: idle * 4)
			#expect(FileManager.default.fileExists(atPath: path))
			gate.open()
			#expect(try await reply.value == .string("done"))
			await server.stopped()
			return
		}
		Issue.record("the resident idled out before a client could connect, in every attempt")
	}
}
