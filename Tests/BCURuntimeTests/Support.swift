import BCUCore
import Foundation
import os
import BCUTestSupport
import Testing

func temporarySocketPath() -> String {
	TemporaryRoot.path("socket") + "/resident.sock"
}

func temporaryDirectory() throws -> String {
	let path = TemporaryRoot.path("files")
	try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
	return path
}

func permissions(_ path: String) throws -> Int {
	(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber).intValue
}

/// Runs a blocking client call on its own thread, the way the CLI process runs it, so the
/// in-process resident keeps the cooperative pool.
func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
	try await withCheckedThrowingContinuation { continuation in
		Thread { continuation.resume(with: Result { try body() }) }.start()
	}
}

func command(_ json: String) throws -> CommandRequest {
	try JSONCoding.decode(CommandRequest.self, from: JSONValue(parsing: json))
}

/// A one-shot latch: `wait` suspends until `open` is called, in either order. A cancelled
/// test (its time limit ran out) opens it, so a broken implementation fails instead of hanging.
final class Gate: Sendable {
	private let state = OSAllocatedUnfairLock<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>(initialState: (false, []))

	func open() {
		let waiters = state.withLock { state in
			state.open = true
			defer { state.waiters = [] }
			return state.waiters
		}
		for waiter in waiters { waiter.resume() }
	}

	func wait() async {
		await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				let resumeNow = state.withLock { state in
					if state.open { return true }
					state.waiters.append(continuation)
					return false
				}
				if resumeNow { continuation.resume() }
			}
		} onCancel: {
			open()
		}
	}
}

final class Counter: Sendable {
	private let value = OSAllocatedUnfairLock(initialState: 0)

	@discardableResult
	func increment() -> Int { value.withLock { $0 += 1; return $0 } }

	var current: Int { value.withLock { $0 } }
}

final class Log: Sendable {
	private let entries = OSAllocatedUnfairLock<[String]>(initialState: [])

	func append(_ entry: String) { entries.withLock { $0.append(entry) } }

	var all: [String] { entries.withLock { $0 } }
}

/// What a resident that died without cleanup leaves behind: a socket file nobody listens on.
func leaveStaleSocket(at path: String) throws {
	try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
	let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
	defer { close(descriptor) }
	var address = sockaddr_un()
	address.sun_family = sa_family_t(AF_UNIX)
	withUnsafeMutableBytes(of: &address.sun_path) { buffer in
		buffer.copyBytes(from: path.utf8)
	}
	let bound = withUnsafePointer(to: &address) {
		$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
	}
	#expect(bound == 0)
}
