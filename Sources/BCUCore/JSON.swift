import Foundation

/// Every JSON document bcu writes — the wire, `--json` and the golden outputs — comes from
/// Foundation's encoder: compact with keys in sorted order, so the same value always has the
/// same bytes; `pretty` is the indented form `inspect-ui` prints.
public enum JSONCoding {
	public static func data<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted] : [.sortedKeys, .withoutEscapingSlashes]
		return try encoder.encode(value)
	}

	public static func string<T: Encodable>(_ value: T, pretty: Bool = false) throws -> String {
		String(decoding: try data(value, pretty: pretty), as: UTF8.self)
	}

	public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
		try JSONDecoder().decode(type, from: data)
	}

	/// A typed value out of a dynamic document, such as a result carried on the wire.
	public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
		try decode(type, from: data(value))
	}

	public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
		try decode(JSONValue.self, from: data(value))
	}
}

/// A JSON document whose shape is only known at run time: an act-ui item before it is
/// checked, a result the resident hands over without the client's types, the config file.
public indirect enum JSONValue: Codable, Sendable, Equatable {
	case null
	case bool(Bool)
	case number(Double)
	case string(String)
	case array([JSONValue])
	case object([String: JSONValue])

	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() {
			self = .null
		} else if let value = try? container.decode(Bool.self) {
			self = .bool(value)
		} else if let value = try? container.decode(Double.self) {
			self = .number(value)
		} else if let value = try? container.decode(String.self) {
			self = .string(value)
		} else if let value = try? container.decode([JSONValue].self) {
			self = .array(value)
		} else {
			self = .object(try container.decode([String: JSONValue].self))
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .null: try container.encodeNil()
		case .bool(let value): try container.encode(value)
		case .number(let value): try container.encode(value)
		case .string(let value): try container.encode(value)
		case .array(let value): try container.encode(value)
		case .object(let value): try container.encode(value)
		}
	}

	public init(parsing text: String) throws {
		self = try JSONCoding.decode(JSONValue.self, from: Data(text.utf8))
	}

	/// The compact text form. Only a non-finite number fails to encode, and a document holds
	/// none: it is parsed from JSON text or built from finite counts.
	public func serialized() -> String {
		try! JSONCoding.string(self)
	}

	public subscript(key: String) -> JSONValue? {
		guard case .object(let members) = self else { return nil }
		return members[key]
	}

	public var string: String? {
		if case .string(let value) = self { return value }
		return nil
	}

	public var number: Double? {
		if case .number(let value) = self { return value }
		return nil
	}

	public var bool: Bool? {
		if case .bool(let value) = self { return value }
		return nil
	}

	public var array: [JSONValue]? {
		if case .array(let value) = self { return value }
		return nil
	}
}
