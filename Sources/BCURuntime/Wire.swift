/// The CLI ↔ resident wire: one JSON value per line over a Unix socket. A connection opens
/// with the resident's `{"hello":ResidentStatus}`, then carries requests
/// `{"command":…,"params":…}` answered by `{"result":…}` or `{"error":BCUError}`. There is no
/// protocol version: a client only talks to a resident of its own app's version (see
/// `Client.connectOrStart`).
import BCUCore
import Foundation

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

/// What a running resident reports about itself; the first thing a client reads.
public struct ResidentStatus: Codable, Sendable, Equatable {
	public var pid: Int
	/// The version of the app the resident runs from.
	public var version: String
}

/// The first line of a connection, sent by the resident.
struct Hello: Codable {
	var hello: ResidentStatus
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
