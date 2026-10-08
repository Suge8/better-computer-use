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

	/// Nil when the resident hung up without greeting: it was shutting down, so none is running.
	fileprivate init?(_ descriptor: Int32) throws {
		channel = LineChannel(descriptor)
		do {
			guard let hello = try channel.read(Hello.self) else {
				Darwin.close(descriptor)
				return nil
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
	/// The running resident, whatever version it is, or nil when none listens; never starts one.
	public static func connectIfRunning(socketPath: String) throws -> Connection? {
		guard case .connected(let descriptor) = try connectSocket(socketPath) else { return nil }
		return try Connection(descriptor)
	}

	/// Connects to a resident of `version`, the version of the app on disk that would be started.
	/// A resident of any other version is left over from before an upgrade: it is stopped and
	/// replaced. Concurrent callers serialize on a user-level lock, so exactly one of them
	/// replaces and launches; the rest find the new resident listening.
	public static func connectOrStart(socketPath: String, version: String, readyTimeout: Duration = .seconds(15), launcher: Launcher) throws -> Connection {
		if let connection = try running(socketPath, version) { return connection }
		let directory = (socketPath as NSString).deletingLastPathComponent
		try ensurePrivateDirectory(directory)
		return try LockFile(socketPath + ".launch.lock").withLock {
			if let connection = try running(socketPath, version) { return connection }
			_ = try stop(socketPath: socketPath)
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
				if let connection = try running(socketPath, version) { return connection }
				guard watcher.waitForChange(until: deadline) else {
					throw BCUError(.residentUnavailable, "The bcu resident process did not start listening at \(socketPath) within \(readyTimeout).")
				}
			}
		}
	}

	/// Stops the running resident, whatever version it is, and returns what it was; nil when
	/// none was running. The socket is gone when this returns.
	public static func stop(socketPath: String) throws -> ResidentStatus? {
		guard let connection = try connectIfRunning(socketPath: socketPath) else { return nil }
		defer { connection.close() }
		_ = try connection.send(.plain(.stop))
		return connection.status
	}

	private static func running(_ socketPath: String, _ version: String) throws -> Connection? {
		guard let connection = try connectIfRunning(socketPath: socketPath) else { return nil }
		return connection.status.version == version ? connection : nil
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
