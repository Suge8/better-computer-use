/// The CLI ↔ resident wire: one JSON value per line over a Unix socket. A connection opens
/// with `{"hello":<client version>}` answered by `{"hello":ResidentStatus}`, then carries
/// requests `{"command":…,"params":…}` answered by `{"result":…}` or `{"error":BCUError}`.
import BCUCore
import Foundation

/// Bumped whenever a request or result changes shape; client and resident must agree.
public let wireProtocolVersion = 2

public enum RuntimePaths {
	private static let caches = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/bcu").path
	public static let socket = caches + "/resident.sock"
	public static let shots = caches + "/shots"
}

public enum Request: Sendable, Equatable {
	case command(CommandRequest)
	case plain(PlainCommand)

	func json() throws -> JSONValue {
		switch self {
		case .command(let command): try JSONCoding.encode(command)
		case .plain(let plain): .object([JSONMember("command", .string(plain.rawValue))])
		}
	}

	init(json: JSONValue) throws {
		if let name = json["command"]?.string, let plain = PlainCommand(rawValue: name) {
			self = .plain(plain)
		} else {
			self = .command(try JSONCoding.decode(CommandRequest.self, from: json))
		}
	}
}

/// What a running resident reports about itself; the answer to every hello.
public struct ResidentStatus: Codable, Sendable, Equatable {
	public var pid: Int
	public var protocolVersion: Int
}

enum Message {
	static func hello(_ version: Int) -> JSONValue {
		.object([JSONMember("hello", .number(Double(version)))])
	}

	static func hello(_ status: ResidentStatus) throws -> JSONValue {
		.object([JSONMember("hello", try JSONCoding.encode(status))])
	}

	static func result(_ value: JSONValue) -> JSONValue {
		.object([JSONMember("result", value)])
	}

	static func error(_ error: BCUError) -> JSONValue {
		.object([JSONMember("error", .object([
			JSONMember("code", .string(error.code.rawValue)),
			JSONMember("message", .string(error.message)),
			JSONMember("recovery", .string(error.recovery)),
		]))])
	}

	/// The result a reply carries, or the error it reports thrown.
	static func unwrap(_ reply: JSONValue) throws -> JSONValue {
		if let error = reply["error"] { throw try JSONCoding.decode(BCUError.self, from: error) }
		guard let result = reply["result"] else { throw BCUError(.residentUnavailable, "The bcu resident process sent a malformed reply.") }
		return result
	}
}
