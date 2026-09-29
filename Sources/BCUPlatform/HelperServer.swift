import AppKit
import Darwin

/// The helper: newline-delimited JSON requests answered through the wire protocol, either
/// as the daemon on a Unix socket (one thread per client, one daemon per socket path) or
/// one at a time on standard input and output.
public final class HelperServer {
	private enum Channel {
		case socket(Int32)
		case standardOutput
	}

	let platform: Platform
	private let completedRequestLock = NSLock()
	private var recentCompletedRequestIds: [String] = []

	/// The agent cursor needs the AppKit run loop that only the daemon runs.
	public init(showsAgentCursor: Bool) {
		platform = Platform(showsAgentCursor: showsAgentCursor)
	}

	/// Serves the socket on a background thread while AppKit owns the main thread.
	public func serve(socketPath: String) -> Never {
		Thread.detachNewThread { [self] in listen(socketPath: socketPath) }
		NSApp.run()
		exit(0)
	}

	/// Answers requests from standard input until it closes.
	public func serveStandardIO() -> Never {
		var buffer = Data()
		let newline = Data([0x0A])
		while true {
			autoreleasepool {
				let data = FileHandle.standardInput.availableData
				if data.isEmpty { exit(0) }
				buffer.append(data)
				while let range = buffer.range(of: newline) {
					let lineData = buffer.subdata(in: 0..<range.lowerBound)
					buffer.removeSubrange(0..<range.upperBound)
					if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { handleLine(line, on: .standardOutput) }
				}
			}
		}
	}

	private func listen(socketPath: String) {
		_ = signal(SIGPIPE, SIG_IGN)
		try? FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
		// LaunchServices may race multiple `open -n` requests while the first
		// daemon is still binding. Keep process ownership separate from socket
		// cleanup so a late launcher can never unlink the live daemon's socket.
		let lockPath = "\(socketPath).lock"
		let lockFile = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
		if lockFile < 0 || flock(lockFile, LOCK_EX | LOCK_NB) != 0 {
			if lockFile >= 0 { close(lockFile) }
			exit(0)
		}
		unlink(socketPath)
		let server = socket(AF_UNIX, SOCK_STREAM, 0)
		if server < 0 { close(lockFile); exit(1) }
		var address = sockaddr_un()
		address.sun_family = sa_family_t(AF_UNIX)
		let sunPathCapacity = MemoryLayout.size(ofValue: address.sun_path)
		let bytes = Array(socketPath.utf8.prefix(sunPathCapacity - 1))
		withUnsafeMutablePointer(to: &address.sun_path) { pointer in
			pointer.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { dest in
				for (index, byte) in bytes.enumerated() { dest[index] = CChar(bitPattern: byte) }
			}
		}
		let bindStatus = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
		}
		if bindStatus != 0 || Darwin.listen(server, 8) != 0 { close(server); close(lockFile); exit(1) }
		while true {
			let client = accept(server, nil, nil)
			if client < 0 { continue }
			var noSigPipe: Int32 = 1
			_ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
			Thread.detachNewThread { [self] in processClient(client) }
		}
	}

	private func processClient(_ client: Int32) {
		let clientInput = FileHandle(fileDescriptor: client, closeOnDealloc: true)
		var buffer = Data()
		let newline = Data([0x0A])
		while true {
			let data = clientInput.availableData
			if data.isEmpty { break }
			buffer.append(data)
			while let range = buffer.range(of: newline) {
				let lineData = buffer.subdata(in: 0..<range.lowerBound)
				buffer.removeSubrange(0..<range.upperBound)
				if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { handleLine(line, on: .socket(client)) }
			}
		}
		clientInput.closeFile()
	}

	private func handleLine(_ line: String, on channel: Channel) {
		let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }

		let fallbackId = "invalid"
		var completionId: String?
		defer {
			if case .socket = channel, let completionId { recordCompletedRequest(completionId) }
		}
		func failure(_ id: String, _ error: Error) -> [String: Any] {
			let reported = error as? PlatformError ?? PlatformError(message: error.localizedDescription, code: "internal_error")
			return ["id": id, "ok": false, "error": ["message": reported.message, "code": reported.code]]
		}
		guard let jsonData = trimmed.data(using: .utf8) else {
			send(failure(fallbackId, PlatformError(message: "Input was not valid UTF-8", code: "invalid_request")), on: channel)
			return
		}
		let object: [String: Any]
		do {
			guard let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
				throw PlatformError(message: "Request must be a JSON object", code: "invalid_request")
			}
			object = parsed
		} catch {
			send(failure(fallbackId, error), on: channel)
			return
		}
		let id = (object["id"] as? String) ?? fallbackId
		completionId = id
		do {
			send(["id": id, "ok": true, "result": try handleRequest(WireRequest(object))], on: channel)
		} catch {
			send(failure(id, error), on: channel)
		}
	}

	private func send(_ payload: [String: Any], on channel: Channel) {
		guard JSONSerialization.isValidJSONObject(payload),
			let data = try? JSONSerialization.data(withJSONObject: payload),
			let line = String(data: data, encoding: .utf8),
			let out = (line + "\n").data(using: .utf8)
		else {
			return
		}
		guard case .socket(let client) = channel else {
			try? FileHandle.standardOutput.write(contentsOf: out)
			return
		}
		out.withUnsafeBytes { raw in
			guard let base = raw.baseAddress else { return }
			var offset = 0
			while offset < raw.count {
				let sent = Darwin.send(client, base.advanced(by: offset), raw.count - offset, 0)
				if sent <= 0 { return }
				offset += sent
			}
		}
	}

	/// The ids of the last requests answered, so a caller can tell whether a request it
	/// abandoned has finished.
	private func recordCompletedRequest(_ id: String) {
		completedRequestLock.lock()
		recentCompletedRequestIds.removeAll { $0 == id }
		recentCompletedRequestIds.append(id)
		if recentCompletedRequestIds.count > 32 {
			recentCompletedRequestIds.removeFirst(recentCompletedRequestIds.count - 32)
		}
		completedRequestLock.unlock()
	}

	func completedRequestIds() -> [String] {
		completedRequestLock.lock()
		defer { completedRequestLock.unlock() }
		return recentCompletedRequestIds
	}
}
