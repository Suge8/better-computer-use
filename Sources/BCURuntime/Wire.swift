/// The CLI ↔ resident wire: one JSON value per line over a Unix socket. A connection opens
/// with `{"hello":<client version>}` answered by `{"hello":ResidentStatus}`, then carries
/// requests `{"command":…,"params":…}` answered by `{"result":…}` or `{"error":BCUError}`.
import BCUCore
import Foundation

/// Bumped whenever a request or result changes shape; client and resident must agree.
public let wireProtocolVersion = 3

public enum RuntimePaths {
	private static let caches = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/bcu").path
	public static let socket = caches + "/resident.sock"
	public static let shots = caches + "/shots"
}

public enum Request: Codable, Sendable, Equatable {
	case command(CommandRequest)
	case plain(PlainCommand)

	private enum CodingKeys: String, CodingKey { case command }

	public init(from decoder: any Decoder) throws {
		let name = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .command)
		self = if let plain = PlainCommand(rawValue: name) { .plain(plain) } else { .command(try CommandRequest(from: decoder)) }
	}

	public func encode(to encoder: any Encoder) throws {
		switch self {
		case .command(let command): try command.encode(to: encoder)
		case .plain(let plain):
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encode(plain.rawValue, forKey: .command)
		}
	}
}

/// What a running resident reports about itself; the answer to every hello.
public struct ResidentStatus: Codable, Sendable, Equatable {
	public var pid: Int
	public var protocolVersion: Int
}

/// The first line each side sends: the client's protocol version, the resident's status.
struct Hello<Content: Codable>: Codable {
	var hello: Content
}

/// A line a client sends: its hello, then requests.
enum Incoming: Decodable {
	case hello(Int)
	case request(Request)

	private enum CodingKeys: String, CodingKey { case hello }

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self = if container.contains(.hello) { .hello(try container.decode(Int.self, forKey: .hello)) } else { .request(try Request(from: decoder)) }
	}
}

/// The answer to one request: its result, or the error it failed with.
struct Reply: Codable {
	var result: JSONValue?
	var error: BCUError?

	func unwrap() throws -> JSONValue {
		if let error { throw error }
		guard let result else { throw BCUError(.residentUnavailable, "The bcu resident process sent a malformed reply.") }
		return result
	}
}
