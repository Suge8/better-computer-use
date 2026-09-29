import BCUCore
import Foundation
import Testing
@testable import BCURuntime

/// The CLI ↔ resident wire: JSON lines over a private Unix socket, typed by the BCUCore contract.
@Suite(.timeLimit(.minutes(1)))
struct IPCTests {
	private func findRootsServer(_ path: String, version: Int = wireProtocolVersion) throws -> Server {
		let server = Server(socketPath: path, protocolVersion: version) { request in
			guard case .command(.findRoots(let params)) = request else { throw BCUError(.invalidArguments, "unexpected request") }
			return try JSONValue(parsing: #"{"roots":[{"ref":"@r1","app":"\#(params.app ?? "")","pid":42,"title":"Doc","kind":"window","frame":{"x":0,"y":0,"w":10,"h":10},"focused":true,"main":true,"onscreen":true,"minimized":false,"modal":false}]}"#)
		}
		#expect(try server.start())
		return server
	}

	@Test func commandAndTypedResultCrossTheSocket() async throws {
		let path = temporarySocketPath()
		let server = try findRootsServer(path)
		defer { server.stop() }
		let result = try await blocking {
			let connection = try #require(try Client.connectIfRunning(socketPath: path))
			defer { connection.close() }
			return try connection.run(try command(#"{"command":"find-roots","params":{"app":"Finder"}}"#))
		}
		guard case .findRoots(let found) = result else { Issue.record("wrong result \(result)"); return }
		#expect(found.roots.map(\.app) == ["Finder"])
		#expect(found.roots.map(\.pid) == [42])
	}

	@Test func socketIsPrivateToTheUser() async throws {
		let path = temporarySocketPath()
		let server = try findRootsServer(path)
		defer { server.stop() }
		#expect(try permissions((path as NSString).deletingLastPathComponent) == 0o700)
		#expect(try permissions(path) == 0o600)
	}

	@Test func handlerErrorReachesTheClientWithItsCode() async throws {
		let path = temporarySocketPath()
		let server = Server(socketPath: path) { _ in throw BCUError(.elementNotFound, "Ref '@e9' is gone.") }
		#expect(try server.start())
		defer { server.stop() }
		let error = await #expect(throws: BCUError.self) {
			try await blocking {
				let connection = try #require(try Client.connectIfRunning(socketPath: path))
				defer { connection.close() }
				_ = try connection.run(try command(#"{"command":"inspect-ui","params":{"stateId":"abcd1234","ref":"@e9"}}"#))
			}
		}
		#expect(error == BCUError(.elementNotFound, "Ref '@e9' is gone."))
	}

	@Test func protocolMismatchIsReportedNotIgnored() async throws {
		let path = temporarySocketPath()
		let server = try findRootsServer(path, version: wireProtocolVersion + 1)
		defer { server.stop() }
		let error = await #expect(throws: BCUError.self) {
			try await blocking { _ = try Client.connectIfRunning(socketPath: path) }
		}
		#expect(error?.code == .brokerUnavailable)
		#expect(error?.message.contains("protocol") == true)
	}

	@Test func residentOfAnotherProtocolCanStillBeStopped() async throws {
		let path = temporarySocketPath()
		let server = try findRootsServer(path, version: wireProtocolVersion + 1)
		let status = try await blocking { try Client.stop(socketPath: path) }
		#expect(status?.pid == Int(getpid()))
		await server.stopped()
		#expect(!FileManager.default.fileExists(atPath: path))
	}
}
