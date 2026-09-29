/// The resident side of the wire: listens on the private socket, answers hellos, `status` and
/// `stop` itself, hands every other request to its handler, and exits after sitting idle.
import BCUCore
import Foundation
import os

public typealias RequestHandler = @Sendable (Request) async throws -> JSONValue

public final class Server: @unchecked Sendable {
	private let socketPath: String
	private let idleTimeout: Duration
	private let status: ResidentStatus
	private let handler: RequestHandler
	/// Guards publishing and removing the socket path, between residents and across processes.
	private var startLock: LockFile?
	/// Owns everything below; listener events and connection bookkeeping all run on it.
	private let queue = DispatchQueue(label: "bcu.resident")
	private var listener: (any DispatchSourceRead)?
	private var connections: Set<Int32> = []
	private var idleTimer: DispatchWorkItem?
	private var stopped = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	public init(socketPath: String, idleTimeout: Duration = .seconds(600), protocolVersion: Int = wireProtocolVersion, handler: @escaping RequestHandler) {
		self.socketPath = socketPath
		self.idleTimeout = idleTimeout
		self.status = ResidentStatus(pid: Int(getpid()), protocolVersion: protocolVersion)
		self.handler = handler
	}

	/// Starts listening; false when another resident already listens at the path. The socket
	/// appears at its path already listening and private, so a client that sees it can connect.
	public func start() throws -> Bool {
		let directory = (socketPath as NSString).deletingLastPathComponent
		try ensurePrivateDirectory(directory)
		let lock = try LockFile(socketPath + ".lock")
		let descriptor: Int32? = try lock.withLock {
			if case .connected(let running) = try connectSocket(socketPath) {
				close(running)
				return nil
			}
			unlink(socketPath)
			let staging = directory + "/.bind-\(String(UInt32.random(in: 0...UInt32.max), radix: 16))"
			let descriptor = try listenSocket(staging)
			guard chmod(staging, 0o600) == 0, rename(staging, socketPath) == 0 else {
				let failure = posixFailure("Cannot publish \(socketPath)")
				unlink(staging)
				close(descriptor)
				throw failure
			}
			return descriptor
		}
		guard let descriptor else { return false }
		_ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
		queue.sync {
			startLock = lock
			beginAccepting(descriptor)
		}
		return true
	}

	/// Returns once the resident has stopped listening: after idling, a stop request or `stop()`.
	public func stopped() async {
		await withCheckedContinuation { continuation in
			queue.async {
				if self.stopped { continuation.resume() } else { self.waiters.append(continuation) }
			}
		}
	}

	public func stop() {
		queue.async { self.shutDown(keeping: nil) }
	}

	// MARK: - on queue

	/// The source holds the server while it listens, so a started resident needs no other owner.
	private func beginAccepting(_ descriptor: Int32) {
		let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
		source.setEventHandler { [self] in acceptPending(descriptor) }
		source.setCancelHandler { close(descriptor) }
		listener = source
		source.resume()
		scheduleIdle()
	}

	private func acceptPending(_ listening: Int32) {
		while !stopped {
			let descriptor = accept(listening, nil, nil)
			guard descriptor >= 0 else { return }
			_ = fcntl(descriptor, F_SETFL, 0)
			var on: Int32 = 1
			setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
			connections.insert(descriptor)
			idleTimer?.cancel()
			// Reads block, so each connection gets its own thread, off the cooperative pool.
			Thread { [self] in serve(descriptor) }.start()
		}
	}

	private func scheduleIdle() {
		idleTimer?.cancel()
		guard !stopped, connections.isEmpty else { return }
		let timer = DispatchWorkItem { [self] in shutDown(keeping: nil) }
		idleTimer = timer
		queue.asyncAfter(deadline: .now() + .nanoseconds(Int(idleTimeout.nanoseconds)), execute: timer)
	}

	/// Stops accepting and removes the socket, so `status` right after sees nothing running.
	/// Other connections are cut; `keeping` is the one that asked to stop and still needs its reply.
	private func shutDown(keeping requester: Int32?) {
		guard !stopped else { return }
		stopped = true
		idleTimer?.cancel()
		// Under the start lock: a resident starting now must not publish its socket and then
		// lose it to this unlink.
		startLock?.withLock { _ = unlink(socketPath) }
		startLock = nil
		listener?.cancel()
		listener = nil
		for descriptor in connections where descriptor != requester { shutdown(descriptor, SHUT_RDWR) }
		for waiter in waiters { waiter.resume() }
		waiters = []
	}

	// MARK: - per connection, on its own thread

	private func serve(_ descriptor: Int32) {
		var channel = LineChannel(descriptor)
		var open = true
		while open {
			let reply: JSONValue
			do {
				guard let message = try channel.read() else { break }
				(reply, open) = respond(to: message, on: descriptor)
			} catch {
				reply = Message.error(BCUError(.internalError, "The bcu resident process received a malformed request: \(error)"))
			}
			// A failed write means the client is gone; there is no one left to tell.
			if (try? channel.write(reply)) == nil { break }
		}
		// Forgotten before closing: once closed, accept may hand the same number to a new client.
		queue.sync {
			_ = connections.remove(descriptor)
			scheduleIdle()
		}
		close(descriptor)
	}

	/// The reply to one message, and whether the connection stays open after it.
	private func respond(to message: JSONValue, on descriptor: Int32) -> (JSONValue, Bool) {
		do {
			if message["hello"] != nil { return (try Message.hello(status), true) }
			let request = try Request(json: message)
			switch request {
			case .plain(.status): return (Message.result(try JSONCoding.encode(status)), true)
			case .plain(.stop):
				queue.sync { shutDown(keeping: descriptor) }
				return (Message.result(try JSONCoding.encode(status)), false)
			default: return (Message.result(try handle(request)), true)
			}
		} catch {
			return (Message.error(BCUError.normalize(error)), true)
		}
	}

	/// Runs the async handler and blocks this connection's thread until it answers.
	private func handle(_ request: Request) throws -> JSONValue {
		let outcome = OSAllocatedUnfairLock<Result<JSONValue, any Error>?>(initialState: nil)
		let answered = DispatchSemaphore(value: 0)
		Task { [handler] in
			let result = await Result(catching: { try await handler(request) })
			outcome.withLock { $0 = result }
			answered.signal()
		}
		answered.wait()
		return try outcome.withLock { $0! }.get()
	}
}

extension Result where Failure == any Error {
	init(catching body: () async throws -> Success) async {
		do {
			self = .success(try await body())
		} catch {
			self = .failure(error)
		}
	}
}
