/// A JSON document that keeps object keys in order. Its text form is byte-identical to
/// `JSON.stringify`, which is what agents and the golden outputs have always read.
public indirect enum JSONValue: Sendable, Equatable {
	case null
	case bool(Bool)
	case number(Double)
	case string(String)
	case array([JSONValue])
	case object([JSONMember])
}

public struct JSONMember: Sendable, Equatable {
	public var key: String
	public var value: JSONValue

	public init(_ key: String, _ value: JSONValue) {
		self.key = key
		self.value = value
	}
}

public struct JSONParseError: Error, Sendable, CustomStringConvertible {
	public let description: String
}

extension JSONValue {
	public subscript(key: String) -> JSONValue? {
		guard case .object(let members) = self else { return nil }
		return members.first { $0.key == key }?.value
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

	/// `JSON.stringify(value)`, or `JSON.stringify(value, null, indent)` when `indent > 0`.
	public func serialized(indent: Int = 0, sortedKeys: Bool = false) -> String {
		var output = ""
		write(to: &output, indent: indent, level: 0, sortedKeys: sortedKeys)
		return output
	}

	private func write(to output: inout String, indent: Int, level: Int, sortedKeys: Bool) {
		switch self {
		case .null: output += "null"
		case .bool(let value): output += value ? "true" : "false"
		case .number(let value): output += value.isFinite ? Text.number(value) : "null"
		case .string(let value): output += Text.quote(value)
		case .array(let items):
			writeContainer(to: &output, open: "[", close: "]", count: items.count, indent: indent, level: level) { index, output in
				items[index].write(to: &output, indent: indent, level: level + 1, sortedKeys: sortedKeys)
			}
		case .object(let members):
			let ordered = sortedKeys ? members.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) } : members
			writeContainer(to: &output, open: "{", close: "}", count: ordered.count, indent: indent, level: level) { index, output in
				output += Text.quote(ordered[index].key)
				output += indent > 0 ? ": " : ":"
				ordered[index].value.write(to: &output, indent: indent, level: level + 1, sortedKeys: sortedKeys)
			}
		}
	}

	private func writeContainer(to output: inout String, open: String, close: String, count: Int, indent: Int, level: Int, item: (Int, inout String) -> Void) {
		output += open
		guard count > 0 else { return output += close }
		let inner = indent > 0 ? "\n" + String(repeating: " ", count: indent * (level + 1)) : ""
		for index in 0..<count {
			output += index == 0 ? inner : "," + inner
			item(index, &output)
		}
		if indent > 0 { output += "\n" + String(repeating: " ", count: indent * level) }
		output += close
	}
}

// MARK: - parsing

extension JSONValue {
	/// Parses like `JSON.parse`: a repeated key keeps its first position and its last value.
	public init(parsing text: String) throws(JSONParseError) {
		var parser = JSONParser(bytes: Array(text.utf8))
		self = try parser.document()
	}
}

private struct JSONParser {
	let bytes: [UInt8]
	var index = 0

	init(bytes: [UInt8]) {
		self.bytes = bytes
	}

	mutating func document() throws(JSONParseError) -> JSONValue {
		let value = try self.value()
		skipWhitespace()
		guard index == bytes.count else { throw failure("Unexpected data after the JSON value") }
		return value
	}

	private func failure(_ message: String) -> JSONParseError {
		JSONParseError(description: "\(message) at position \(index)")
	}

	private mutating func skipWhitespace() {
		while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
	}

	private mutating func value() throws(JSONParseError) -> JSONValue {
		skipWhitespace()
		guard index < bytes.count else { throw failure("Unexpected end of JSON input") }
		switch bytes[index] {
		case UInt8(ascii: "{"): return try object()
		case UInt8(ascii: "["): return try array()
		case UInt8(ascii: "\""): return .string(try string())
		case UInt8(ascii: "t"): return try literal("true", .bool(true))
		case UInt8(ascii: "f"): return try literal("false", .bool(false))
		case UInt8(ascii: "n"): return try literal("null", .null)
		default: return .number(try number())
		}
	}

	private mutating func literal(_ word: String, _ value: JSONValue) throws(JSONParseError) -> JSONValue {
		let expected = Array(word.utf8)
		guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else { throw failure("Unexpected token") }
		index += expected.count
		return value
	}

	private mutating func expect(_ byte: UInt8) throws(JSONParseError) {
		skipWhitespace()
		guard index < bytes.count, bytes[index] == byte else { throw failure("Expected '\(Character(Unicode.Scalar(byte)))'") }
		index += 1
	}

	private mutating func consume(_ byte: UInt8) -> Bool {
		skipWhitespace()
		guard index < bytes.count, bytes[index] == byte else { return false }
		index += 1
		return true
	}

	private mutating func object() throws(JSONParseError) -> JSONValue {
		index += 1
		var members: [JSONMember] = []
		if consume(UInt8(ascii: "}")) { return .object(members) }
		repeat {
			skipWhitespace()
			guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw failure("Expected a property name") }
			let key = try string()
			try expect(UInt8(ascii: ":"))
			let value = try self.value()
			if let existing = members.firstIndex(where: { $0.key == key }) {
				members[existing].value = value
			} else {
				members.append(JSONMember(key, value))
			}
		} while consume(UInt8(ascii: ","))
		try expect(UInt8(ascii: "}"))
		return .object(members)
	}

	private mutating func array() throws(JSONParseError) -> JSONValue {
		index += 1
		var items: [JSONValue] = []
		if consume(UInt8(ascii: "]")) { return .array(items) }
		repeat { items.append(try value()) } while consume(UInt8(ascii: ","))
		try expect(UInt8(ascii: "]"))
		return .array(items)
	}

	private mutating func number() throws(JSONParseError) -> Double {
		let start = index
		func digits(_ parser: inout JSONParser) -> Int {
			let from = parser.index
			while parser.index < parser.bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(parser.bytes[parser.index]) { parser.index += 1 }
			return parser.index - from
		}
		if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
		let integer = digits(&self)
		guard integer > 0, !(integer > 1 && bytes[index - integer] == UInt8(ascii: "0")) else { throw failure("Unexpected token") }
		if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
			index += 1
			guard digits(&self) > 0 else { throw failure("Unterminated fractional number") }
		}
		if index < bytes.count, bytes[index] | 0x20 == UInt8(ascii: "e") {
			index += 1
			if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
			guard digits(&self) > 0 else { throw failure("Exponent part is missing a number") }
		}
		guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else { throw failure("Invalid number") }
		return value
	}

	private mutating func string() throws(JSONParseError) -> String {
		index += 1
		var units: [UInt16] = []
		var start = index
		func flush(_ parser: JSONParser, _ units: inout [UInt16], upTo end: Int) {
			units.append(contentsOf: String(decoding: parser.bytes[start..<end], as: UTF8.self).utf16)
		}
		while index < bytes.count {
			let byte = bytes[index]
			if byte == UInt8(ascii: "\"") {
				flush(self, &units, upTo: index)
				index += 1
				return String(decoding: units, as: UTF16.self)
			}
			guard byte >= 0x20 else { throw failure("Bad control character in string literal") }
			guard byte == UInt8(ascii: "\\") else {
				index += 1
				continue
			}
			flush(self, &units, upTo: index)
			index += 1
			guard index < bytes.count else { break }
			let escape = bytes[index]
			index += 1
			switch escape {
			case UInt8(ascii: "\""): units.append(0x22)
			case UInt8(ascii: "\\"): units.append(0x5C)
			case UInt8(ascii: "/"): units.append(0x2F)
			case UInt8(ascii: "b"): units.append(0x08)
			case UInt8(ascii: "f"): units.append(0x0C)
			case UInt8(ascii: "n"): units.append(0x0A)
			case UInt8(ascii: "r"): units.append(0x0D)
			case UInt8(ascii: "t"): units.append(0x09)
			case UInt8(ascii: "u"):
				guard index + 4 <= bytes.count, let unit = UInt16(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else { throw failure("Bad Unicode escape") }
				units.append(unit)
				index += 4
			default: throw failure("Bad escaped character")
			}
			start = index
		}
		throw failure("Unterminated string")
	}
}
