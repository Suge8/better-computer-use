/// Codable to and from `JSONValue`. Encoding keeps the order properties are encoded in, and
/// decoding hands keyed containers their keys in document order, so a decoded result
/// re-encodes to the same bytes.
public enum JSONCoding {
	public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
		let slot = Slot()
		try slot.encode(value, codingPath: [])
		return slot.resolved
	}

	public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
		try ValueDecoder(value: value, codingPath: []).decode(type)
	}

	public static func string<T: Encodable>(_ value: T, indent: Int = 0, sortedKeys: Bool = false) throws -> String {
		try encode(value).serialized(indent: indent, sortedKeys: sortedKeys)
	}
}

struct AnyKey: CodingKey {
	let stringValue: String
	let intValue: Int?

	init(stringValue: String) {
		self.stringValue = stringValue
		intValue = nil
	}

	init(intValue: Int) {
		stringValue = String(intValue)
		self.intValue = intValue
	}
}

// MARK: - encoding

private final class Slot {
	enum Content {
		case empty
		case value(JSONValue)
		case object(keys: [String], slots: [String: Slot])
		case array([Slot])
	}

	var content = Content.empty

	var resolved: JSONValue {
		switch content {
		case .empty: .null
		case .value(let value): value
		case .object(let keys, let slots): .object(keys.map { JSONMember($0, slots[$0]!.resolved) })
		case .array(let slots): .array(slots.map(\.resolved))
		}
	}

	func encode<T: Encodable>(_ value: T, codingPath: [any CodingKey]) throws {
		if let json = value as? JSONValue {
			content = .value(json)
		} else {
			try value.encode(to: ValueEncoder(slot: self, codingPath: codingPath))
		}
	}

	func member(_ key: String) -> Slot {
		if case .object(var keys, var slots) = content {
			if let existing = slots[key] { return existing }
			let slot = Slot()
			keys.append(key)
			slots[key] = slot
			content = .object(keys: keys, slots: slots)
			return slot
		}
		let slot = Slot()
		content = .object(keys: [key], slots: [key: slot])
		return slot
	}

	func makeObject() {
		if case .object = content { return }
		content = .object(keys: [], slots: [:])
	}

	func append() -> Slot {
		let slot = Slot()
		if case .array(let slots) = content {
			content = .array(slots + [slot])
		} else {
			content = .array([slot])
		}
		return slot
	}

	func makeArray() {
		if case .array = content { return }
		content = .array([])
	}
}

private struct ValueEncoder: Encoder {
	let slot: Slot
	let codingPath: [any CodingKey]
	var userInfo: [CodingUserInfoKey: Any] { [:] }

	func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
		slot.makeObject()
		return KeyedEncodingContainer(KeyedEncoder<Key>(slot: slot, codingPath: codingPath))
	}

	func unkeyedContainer() -> any UnkeyedEncodingContainer {
		slot.makeArray()
		return UnkeyedEncoder(slot: slot, codingPath: codingPath)
	}

	func singleValueContainer() -> any SingleValueEncodingContainer {
		SingleEncoder(slot: slot, codingPath: codingPath)
	}
}

private struct KeyedEncoder<Key: CodingKey>: KeyedEncodingContainerProtocol {
	let slot: Slot
	let codingPath: [any CodingKey]

	private func set(_ value: JSONValue, _ key: Key) {
		slot.member(key.stringValue).content = .value(value)
	}

	mutating func encodeNil(forKey key: Key) throws { set(.null, key) }
	mutating func encode(_ value: Bool, forKey key: Key) throws { set(.bool(value), key) }
	mutating func encode(_ value: String, forKey key: Key) throws { set(.string(value), key) }
	mutating func encode(_ value: Double, forKey key: Key) throws { set(.number(value), key) }
	mutating func encode(_ value: Float, forKey key: Key) throws { set(.number(Double(value)), key) }
	mutating func encode(_ value: Int, forKey key: Key) throws { set(.number(Double(value)), key) }
	mutating func encode(_ value: Int8, forKey key: Key) throws { set(.number(Double(value)), key) }
	mutating func encode(_ value: Int16, forKey key: Key) throws { set(.number(Double(value)), key) }
	mutating func encode(_ value: Int32, forKey key: Key) throws { set(.number(Double(value)), key) }
	mutating func encode(_ value: Int64, forKey key: Key) throws { set(.number(Double(value)), key) }
	mutating func encode(_ value: UInt, forKey key: Key) throws { set(.number(Double(value)), key) }
	mutating func encode(_ value: UInt8, forKey key: Key) throws { set(.number(Double(value)), key) }
	mutating func encode(_ value: UInt16, forKey key: Key) throws { set(.number(Double(value)), key) }
	mutating func encode(_ value: UInt32, forKey key: Key) throws { set(.number(Double(value)), key) }
	mutating func encode(_ value: UInt64, forKey key: Key) throws { set(.number(Double(value)), key) }

	mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
		try slot.member(key.stringValue).encode(value, codingPath: codingPath + [key])
	}

	mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
		ValueEncoder(slot: slot.member(key.stringValue), codingPath: codingPath + [key]).container(keyedBy: keyType)
	}

	mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
		ValueEncoder(slot: slot.member(key.stringValue), codingPath: codingPath + [key]).unkeyedContainer()
	}

	mutating func superEncoder() -> any Encoder {
		ValueEncoder(slot: slot.member("super"), codingPath: codingPath + [AnyKey(stringValue: "super")])
	}

	mutating func superEncoder(forKey key: Key) -> any Encoder {
		ValueEncoder(slot: slot.member(key.stringValue), codingPath: codingPath + [key])
	}
}

private struct UnkeyedEncoder: UnkeyedEncodingContainer {
	let slot: Slot
	let codingPath: [any CodingKey]
	var count: Int {
		if case .array(let slots) = slot.content { return slots.count }
		return 0
	}

	private func next() -> (Slot, [any CodingKey]) {
		let path = codingPath + [AnyKey(intValue: count)]
		return (slot.append(), path)
	}

	private func append(_ value: JSONValue) {
		slot.append().content = .value(value)
	}

	mutating func encodeNil() throws { append(.null) }
	mutating func encode(_ value: Bool) throws { append(.bool(value)) }
	mutating func encode(_ value: String) throws { append(.string(value)) }
	mutating func encode(_ value: Double) throws { append(.number(value)) }
	mutating func encode(_ value: Float) throws { append(.number(Double(value))) }
	mutating func encode(_ value: Int) throws { append(.number(Double(value))) }
	mutating func encode(_ value: Int8) throws { append(.number(Double(value))) }
	mutating func encode(_ value: Int16) throws { append(.number(Double(value))) }
	mutating func encode(_ value: Int32) throws { append(.number(Double(value))) }
	mutating func encode(_ value: Int64) throws { append(.number(Double(value))) }
	mutating func encode(_ value: UInt) throws { append(.number(Double(value))) }
	mutating func encode(_ value: UInt8) throws { append(.number(Double(value))) }
	mutating func encode(_ value: UInt16) throws { append(.number(Double(value))) }
	mutating func encode(_ value: UInt32) throws { append(.number(Double(value))) }
	mutating func encode(_ value: UInt64) throws { append(.number(Double(value))) }

	mutating func encode<T: Encodable>(_ value: T) throws {
		let (child, path) = next()
		try child.encode(value, codingPath: path)
	}

	mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
		let (child, path) = next()
		return ValueEncoder(slot: child, codingPath: path).container(keyedBy: keyType)
	}

	mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
		let (child, path) = next()
		return ValueEncoder(slot: child, codingPath: path).unkeyedContainer()
	}

	mutating func superEncoder() -> any Encoder {
		let (child, path) = next()
		return ValueEncoder(slot: child, codingPath: path)
	}
}

private struct SingleEncoder: SingleValueEncodingContainer {
	let slot: Slot
	let codingPath: [any CodingKey]

	private func set(_ value: JSONValue) {
		slot.content = .value(value)
	}

	mutating func encodeNil() throws { set(.null) }
	mutating func encode(_ value: Bool) throws { set(.bool(value)) }
	mutating func encode(_ value: String) throws { set(.string(value)) }
	mutating func encode(_ value: Double) throws { set(.number(value)) }
	mutating func encode(_ value: Float) throws { set(.number(Double(value))) }
	mutating func encode(_ value: Int) throws { set(.number(Double(value))) }
	mutating func encode(_ value: Int8) throws { set(.number(Double(value))) }
	mutating func encode(_ value: Int16) throws { set(.number(Double(value))) }
	mutating func encode(_ value: Int32) throws { set(.number(Double(value))) }
	mutating func encode(_ value: Int64) throws { set(.number(Double(value))) }
	mutating func encode(_ value: UInt) throws { set(.number(Double(value))) }
	mutating func encode(_ value: UInt8) throws { set(.number(Double(value))) }
	mutating func encode(_ value: UInt16) throws { set(.number(Double(value))) }
	mutating func encode(_ value: UInt32) throws { set(.number(Double(value))) }
	mutating func encode(_ value: UInt64) throws { set(.number(Double(value))) }

	mutating func encode<T: Encodable>(_ value: T) throws {
		try slot.encode(value, codingPath: codingPath)
	}
}

// MARK: - decoding

private struct ValueDecoder: Decoder, SingleValueDecodingContainer {
	let value: JSONValue
	let codingPath: [any CodingKey]
	var userInfo: [CodingUserInfoKey: Any] { [:] }

	func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
		guard case .object(let members) = value else { throw mismatch([String: JSONValue].self) }
		return KeyedDecodingContainer(KeyedDecoder<Key>(members: members, codingPath: codingPath))
	}

	func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
		guard case .array(let items) = value else { throw mismatch([JSONValue].self) }
		return UnkeyedDecoder(items: items, codingPath: codingPath)
	}

	func singleValueContainer() throws -> any SingleValueDecodingContainer { self }

	func mismatch(_ type: Any.Type) -> DecodingError {
		DecodingError.typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Expected \(type), found \(value.serialized())"))
	}

	func decodeNil() -> Bool { value == .null }

	func decode(_ type: Bool.Type) throws -> Bool {
		guard case .bool(let flag) = value else { throw mismatch(type) }
		return flag
	}

	func decode(_ type: String.Type) throws -> String {
		guard case .string(let text) = value else { throw mismatch(type) }
		return text
	}

	func decode(_ type: Double.Type) throws -> Double {
		guard case .number(let number) = value else { throw mismatch(type) }
		return number
	}

	func decode(_ type: Float.Type) throws -> Float { Float(try decode(Double.self)) }

	private func integer<T: BinaryInteger>(_ type: T.Type) throws -> T {
		guard case .number(let number) = value, let exact = T(exactly: number) else { throw mismatch(type) }
		return exact
	}

	func decode(_ type: Int.Type) throws -> Int { try integer(type) }
	func decode(_ type: Int8.Type) throws -> Int8 { try integer(type) }
	func decode(_ type: Int16.Type) throws -> Int16 { try integer(type) }
	func decode(_ type: Int32.Type) throws -> Int32 { try integer(type) }
	func decode(_ type: Int64.Type) throws -> Int64 { try integer(type) }
	func decode(_ type: UInt.Type) throws -> UInt { try integer(type) }
	func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(type) }
	func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(type) }
	func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(type) }
	func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(type) }

	func decode<T: Decodable>(_ type: T.Type) throws -> T {
		if let json = value as? T { return json }
		return try T(from: self)
	}
}

private struct KeyedDecoder<Key: CodingKey>: KeyedDecodingContainerProtocol {
	let members: [JSONMember]
	let codingPath: [any CodingKey]

	var allKeys: [Key] { members.compactMap { Key(stringValue: $0.key) } }

	func contains(_ key: Key) -> Bool {
		members.contains { $0.key == key.stringValue }
	}

	private func child(_ key: Key) throws -> ValueDecoder {
		guard let member = members.first(where: { $0.key == key.stringValue }) else {
			throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "No value for key '\(key.stringValue)'"))
		}
		return ValueDecoder(value: member.value, codingPath: codingPath + [key])
	}

	func decodeNil(forKey key: Key) throws -> Bool { try child(key).decodeNil() }
	func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try child(key).decode(type) }
	func decode(_ type: String.Type, forKey key: Key) throws -> String { try child(key).decode(type) }
	func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try child(key).decode(type) }
	func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try child(key).decode(type) }
	func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try child(key).decode(type) }
	func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try child(key).decode(type) }
	func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try child(key).decode(type) }
	func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try child(key).decode(type) }
	func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try child(key).decode(type) }
	func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try child(key).decode(type) }
	func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try child(key).decode(type) }
	func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try child(key).decode(type) }
	func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try child(key).decode(type) }
	func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try child(key).decode(type) }
	func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try child(key).decode(type) }

	func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
		try child(key).container(keyedBy: type)
	}

	func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
		try child(key).unkeyedContainer()
	}

	func superDecoder() throws -> any Decoder { try child(Key(stringValue: "super")!) }
	func superDecoder(forKey key: Key) throws -> any Decoder { try child(key) }
}

private struct UnkeyedDecoder: UnkeyedDecodingContainer {
	let items: [JSONValue]
	let codingPath: [any CodingKey]
	var currentIndex = 0
	var count: Int? { items.count }
	var isAtEnd: Bool { currentIndex >= items.count }

	init(items: [JSONValue], codingPath: [any CodingKey]) {
		self.items = items
		self.codingPath = codingPath
	}

	private mutating func next() throws -> ValueDecoder {
		guard !isAtEnd else {
			throw DecodingError.valueNotFound(JSONValue.self, .init(codingPath: codingPath, debugDescription: "Unkeyed container is at its end"))
		}
		defer { currentIndex += 1 }
		return ValueDecoder(value: items[currentIndex], codingPath: codingPath + [AnyKey(intValue: currentIndex)])
	}

	mutating func decodeNil() throws -> Bool {
		guard !isAtEnd, items[currentIndex] == .null else { return false }
		currentIndex += 1
		return true
	}

	mutating func decode(_ type: Bool.Type) throws -> Bool { try next().decode(type) }
	mutating func decode(_ type: String.Type) throws -> String { try next().decode(type) }
	mutating func decode(_ type: Double.Type) throws -> Double { try next().decode(type) }
	mutating func decode(_ type: Float.Type) throws -> Float { try next().decode(type) }
	mutating func decode(_ type: Int.Type) throws -> Int { try next().decode(type) }
	mutating func decode(_ type: Int8.Type) throws -> Int8 { try next().decode(type) }
	mutating func decode(_ type: Int16.Type) throws -> Int16 { try next().decode(type) }
	mutating func decode(_ type: Int32.Type) throws -> Int32 { try next().decode(type) }
	mutating func decode(_ type: Int64.Type) throws -> Int64 { try next().decode(type) }
	mutating func decode(_ type: UInt.Type) throws -> UInt { try next().decode(type) }
	mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try next().decode(type) }
	mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try next().decode(type) }
	mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try next().decode(type) }
	mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try next().decode(type) }
	mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try next().decode(type) }

	mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
		try next().container(keyedBy: type)
	}

	mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
		try next().unkeyedContainer()
	}

	mutating func superDecoder() throws -> any Decoder { try next() }
}

// MARK: - ordered maps

/// A JSON object whose key order is part of its bytes: capability owners and folded role counts.
public struct OrderedMap<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
	public private(set) var keys: [String] = []
	private var values: [String: Value] = [:]

	public init() {}

	public var isEmpty: Bool { keys.isEmpty }
	public var entries: [(key: String, value: Value)] { keys.map { ($0, values[$0]!) } }

	public subscript(key: String) -> Value? {
		get { values[key] }
		set {
			if values[key] == nil, newValue != nil { keys.append(key) }
			if newValue == nil { keys.removeAll { $0 == key } }
			values[key] = newValue
		}
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: AnyKey.self)
		for key in container.allKeys { self[key.stringValue] = try container.decode(Value.self, forKey: key) }
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: AnyKey.self)
		for key in keys { try container.encode(values[key]!, forKey: AnyKey(stringValue: key)) }
	}
}
