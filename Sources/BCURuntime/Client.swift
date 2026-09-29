/// The CLI side of the wire: connect to the running resident, start it on demand, stop it.
import BCUCore
import Foundation

/// Starts the resident process and returns without waiting for it to listen.
public typealias Launcher = @Sendable () throws -> Void

/// One handshaken connection to the resident; requests and replies alternate on it.
public final class Connection {
	public let status: ResidentStatus
	private var channel: LineChannel
	private var open = true

	fileprivate init(_ descriptor: Int32, protocolVersion: Int) throws {
		channel = LineChannel(descriptor)
		do {
			try channel.write(Hello(hello: protocolVersion))
			guard let hello = try channel.read(Hello<ResidentStatus>.self) else {
				throw BCUError(.residentUnavailable, "The bcu resident process closed the connection during the handshake.")
			}
			status = hello.hello
		} catch {
			Darwin.close(descriptor)
			throw error
		}
	}

	public func send(_ request: Request) throws -> JSONValue {
		try channel.write(request)
		guard let reply = try channel.read(Reply.self) else { throw BCUError(.residentUnavailable, "The bcu resident process closed the connection.") }
		return try reply.unwrap()
	}

	public func run(_ command: CommandRequest) throws -> CommandResult {
		try CommandResult.decode(command.name, from: send(.command(command)))
	}

	public func close() {
		guard open else { return }
		open = false
		Darwin.close(channel.descriptor)
	}

	deinit { close() }
}

public enum Client {
	/// The running resident, or nil when none listens; never starts one.
	public static func connectIfRunning(socketPath: String, protocolVersion: Int = wireProtocolVersion) throws -> Connection? {
		guard let connection = try handshake(socketPath, protocolVersion) else { return nil }
		guard connection.status.protocolVersion == protocolVersion else {
			throw BCUError(.residentUnavailable, "The running bcu resident process (pid \(connection.status.pid)) speaks protocol \(connection.status.protocolVersion); this bcu speaks \(protocolVersion).", recovery: "Run 'bcu stop', then retry.")
		}
		return connection
	}

	/// Connects, starting the resident first when none listens. Concurrent callers serialize on
	/// a user-level lock, so exactly one of them launches; the rest find it listening.
	public static func connectOrStart(socketPath: String, protocolVersion: Int = wireProtocolVersion, readyTimeout: Duration = .seconds(15), launcher: Launcher) throws -> Connection {
		if let connection = try connectIfRunning(socketPath: socketPath, protocolVersion: protocolVersion) { return connection }
		let directory = (socketPath as NSString).deletingLastPathComponent
		try ensurePrivateDirectory(directory)
		return try LockFile(socketPath + ".launch.lock").withLock {
			if let connection = try connectIfRunning(socketPath: socketPath, protocolVersion: protocolVersion) { return connection }
			// Armed before the launch so the resident's socket appearing cannot slip past unseen.
			let watcher = try DirectoryWatcher(directory)
			defer { watcher.cancel() }
			do {
				try launcher()
			} catch {
				throw BCUError(.residentUnavailable, "Could not start the bcu resident process: \(BCUError.normalize(error).message)")
			}
			let deadline = DispatchTime.now() + .nanoseconds(Int(readyTimeout.nanoseconds))
			while true {
				if let connection = try connectIfRunning(socketPath: socketPath, protocolVersion: protocolVersion) { return connection }
				guard watcher.waitForChange(until: deadline) else {
					throw BCUError(.residentUnavailable, "The bcu resident process did not start listening at \(socketPath) within \(readyTimeout).")
				}
			}
		}
	}

	/// Stops the running resident, whatever protocol it speaks, and returns what it was; nil
	/// when none was running.
	public static func stop(socketPath: String, protocolVersion: Int = wireProtocolVersion) throws -> ResidentStatus? {
		guard let connection = try handshake(socketPath, protocolVersion) else { return nil }
		defer { connection.close() }
		_ = try connection.send(.plain(.stop))
		return connection.status
	}

	private static func handshake(_ socketPath: String, _ protocolVersion: Int) throws -> Connection? {
		guard case .connected(let descriptor) = try connectSocket(socketPath) else { return nil }
		return try Connection(descriptor, protocolVersion: protocolVersion)
	}
}

extension Duration {
	var nanoseconds: Int64 {
		components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
	}
}

/// Wakes on entries appearing, vanishing or being renamed in one directory.
private final class DirectoryWatcher: Sendable {
	private let source: any DispatchSourceFileSystemObject
	private let changed = DispatchSemaphore(value: 0)

	init(_ directory: String) throws {
		let descriptor = open(directory, O_EVTONLY | O_CLOEXEC)
		guard descriptor >= 0 else { throw posixFailure("Cannot watch \(directory)") }
		source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .global())
		source.setEventHandler { [changed] in changed.signal() }
		source.setCancelHandler { close(descriptor) }
		source.resume()
	}

	func waitForChange(until deadline: DispatchTime) -> Bool {
		changed.wait(timeout: deadline) == .success
	}

	func cancel() {
		source.cancel()
	}
}
