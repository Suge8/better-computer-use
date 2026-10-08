import Foundation

/// How the view writes text: whitespace is Swift's (`Character.isWhitespace`), lengths count
/// characters, strings are quoted the way the JSON encoder writes them.
enum Text {
	static func trim(_ value: String) -> String {
		value.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// `value` trimmed when something is left, otherwise nil.
	static func trimmedOrNil(_ value: String?) -> String? {
		guard let trimmed = value.map(trim), !trimmed.isEmpty else { return nil }
		return trimmed
	}

	/// Every whitespace run as one space, none at either end.
	static func normalized(_ value: String) -> String {
		value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	static func padEnd(_ value: String, _ width: Int) -> String {
		value + String(repeating: " ", count: max(0, width - value.count))
	}

	static func quote(_ value: String) -> String {
		try! JSONCoding.string(value)
	}

	/// Numbers as the view prints them: whole values without a fraction, others in their
	/// shortest round-trip form. Covers coordinates, sizes, counts and milliseconds.
	static func number(_ value: Double) -> String {
		if value == value.rounded(), Swift.abs(value) < 1e15 { return String(Int64(value)) }
		return String(describing: value)
	}
}

/// Text as searches compare it: case-insensitive, with three periods read as the ellipsis
/// that macOS titles end in, on both sides of the comparison.
public func foldedForSearch(_ value: String) -> String {
	value.lowercased().replacingOccurrences(of: "...", with: "\u{2026}")
}

extension Character {
	var isASCIIDigit: Bool { isASCII && isNumber }
}
