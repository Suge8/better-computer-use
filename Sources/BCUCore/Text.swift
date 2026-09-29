/// The text rules the public output is written in: which characters count as whitespace
/// when names are cleaned, lengths in UTF-16 units, and JSON string quoting.
enum Text {
	static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
		switch scalar.value {
		case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
		default: false
		}
	}

	static func trim(_ value: String) -> String {
		let scalars = value.unicodeScalars
		guard let first = scalars.firstIndex(where: { !isWhitespace($0) }), let last = scalars.lastIndex(where: { !isWhitespace($0) }) else { return "" }
		return String(scalars[first...last])
	}

	static func trimEnd(_ value: String) -> String {
		let scalars = value.unicodeScalars
		guard let last = scalars.lastIndex(where: { !isWhitespace($0) }) else { return "" }
		return String(scalars[...last])
	}

	/// `value.trim()` when something is left, otherwise nil.
	static func trimmedOrNil(_ value: String?) -> String? {
		guard let value else { return nil }
		let trimmed = trim(value)
		return trimmed.isEmpty ? nil : trimmed
	}

	/// `value.replace(/\s+/g, " ")`.
	static func collapseWhitespace(_ value: String) -> String {
		var output = String.UnicodeScalarView()
		var inRun = false
		for scalar in value.unicodeScalars {
			if isWhitespace(scalar) {
				if !inRun { output.append(" ") }
				inRun = true
			} else {
				output.append(scalar)
				inRun = false
			}
		}
		return String(output)
	}

	static func length(_ value: String) -> Int {
		value.utf16.count
	}

	/// The first `count` UTF-16 units; a cut through a surrogate pair leaves U+FFFD.
	static func prefix(_ value: String, _ count: Int) -> String {
		String(decoding: Array(value.utf16.prefix(count)), as: UTF16.self)
	}

	static func padEnd(_ value: String, _ width: Int) -> String {
		value + String(repeating: " ", count: max(0, width - length(value)))
	}

	/// `JSON.stringify(string)`.
	static func quote(_ value: String) -> String {
		var output = "\""
		for scalar in value.unicodeScalars {
			switch scalar {
			case "\"": output += "\\\""
			case "\\": output += "\\\\"
			case "\u{08}": output += "\\b"
			case "\u{0C}": output += "\\f"
			case "\n": output += "\\n"
			case "\r": output += "\\r"
			case "\t": output += "\\t"
			case _ where scalar.value < 0x20:
				let hex = String(scalar.value, radix: 16)
				output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
			default: output.unicodeScalars.append(scalar)
			}
		}
		return output + "\""
	}

	/// Numbers as the view prints them: whole values without a fraction, others in their
	/// shortest round-trip form. Covers coordinates, sizes, counts and milliseconds.
	static func number(_ value: Double) -> String {
		if value == value.rounded(), Swift.abs(value) < 1e15 { return String(Int64(value)) }
		return String(describing: value)
	}

	/// A parsed JSON value as an error message names it; `undefined` when absent.
	static func describe(_ value: JSONValue?) -> String {
		switch value {
		case nil: "undefined"
		case .null: "null"
		case .bool(let flag): flag ? "true" : "false"
		case .number(let value): Text.number(value)
		case .string(let text): text
		case .array(let items): items.map { $0 == .null ? "" : describe($0) }.joined(separator: ",")
		case .object: "[object Object]"
		}
	}
}

extension Character {
	var isASCIIDigit: Bool { isASCII && isNumber }
}
