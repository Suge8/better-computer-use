/// POSIX pieces shared by client and resident: private directories, the user-level lock
/// files, Unix socket addresses and newline-framed JSON over a blocking descriptor.
import BCUCore
import Foundation

func posixFailure(_ what: String, _ code: Int32 = errno) -> BCUError {
	BCUError(.brokerUnavailable, "\(what): \(String(cString: strerror(code))).")
}

func ensurePrivateDirectory(_ path: String) throws {
	try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
	guard chmod(path, 0o700) == 0 else { throw posixFailure("Cannot restrict \(path)") }
}

/// A user-level lock file; `withLock` holds an exclusive `flock`, waiting for it in the kernel.
final class LockFile: Sendable {
	private let descriptor: Int32

	init(_ path: String) throws {
		descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
		guard descriptor >= 0 else { throw posixFailure("Cannot open lock \(path)") }
	}

	func withLock<T>(_ body: () throws -> T) rethrows -> T {
		// On an open regular file only a signal can interrupt an exclusive, blocking flock.
		while flock(descriptor, LOCK_EX) != 0 { precondition(errno == EINTR, "flock failed: \(errno)") }
		defer { flock(descriptor, LOCK_UN) }
		return try body()
	}

	deinit { close(descriptor) }
}

private func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
	var address = sockaddr_un()
	address.sun_family = sa_family_t(AF_UNIX)
	let bytes = Array(path.utf8)
	guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
		throw BCUError(.brokerUnavailable, "Socket path \(path) is longer than a Unix socket address allows.")
	}
	withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
	return withUnsafePointer(to: &address) {
		$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
	}
}

private func newSocket() throws -> Int32 {
	let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
	guard descriptor >= 0 else { throw posixFailure("Cannot create a socket") }
	var on: Int32 = 1
	setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
	_ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
	return descriptor
}

enum Connect {
	case connected(Int32)
	/// Nothing listens at the path: no file, or a file a dead resident left behind.
	case absent
}

func connectSocket(_ path: String) throws -> Connect {
	let descriptor = try newSocket()
	let result = try withAddress(path) { connect(descriptor, $0, $1) }
	if result == 0 { return .connected(descriptor) }
	let code = errno
	close(descriptor)
	if code == ENOENT || code == ECONNREFUSED { return .absent }
	throw posixFailure("Cannot connect to the bcu resident process at \(path)", code)
}

/// A listening socket bound at `path`, which the caller has already cleared.
func listenSocket(_ path: String) throws -> Int32 {
	let descriptor = try newSocket()
	do {
		guard try withAddress(path, { bind(descriptor, $0, $1) }) == 0 else { throw posixFailure("Cannot bind \(path)") }
		guard listen(descriptor, SOMAXCONN) == 0 else { throw posixFailure("Cannot listen on \(path)") }
		return descriptor
	} catch {
		close(descriptor)
		throw error
	}
}

/// Newline-framed JSON over one blocking descriptor.
struct LineChannel {
	let descriptor: Int32
	private var buffer: [UInt8] = []

	init(_ descriptor: Int32) {
		self.descriptor = descriptor
	}

	/// The next value, or nil once the peer has closed.
	mutating func read() throws -> JSONValue? {
		while true {
			if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
				let line = String(decoding: buffer[..<newline], as: UTF8.self)
				buffer.removeSubrange(...newline)
				return try JSONValue(parsing: line)
			}
			var chunk = [UInt8](repeating: 0, count: 64 * 1024)
			let count = Foundation.read(descriptor, &chunk, chunk.count)
			if count > 0 {
				buffer.append(contentsOf: chunk[..<count])
			} else if count == 0 || errno != EINTR {
				return nil
			}
		}
	}

	func write(_ value: JSONValue) throws {
		let bytes = Array((value.serialized() + "\n").utf8)
		var offset = 0
		while offset < bytes.count {
			let written = bytes[offset...].withUnsafeBytes { Foundation.write(descriptor, $0.baseAddress, $0.count) }
			if written < 0 {
				if errno == EINTR { continue }
				throw posixFailure("The bcu connection closed")
			}
			offset += written
		}
	}
}
