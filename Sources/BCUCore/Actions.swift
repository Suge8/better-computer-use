/// The act-ui boundary: checks a caller's action array before anything is delivered, and
/// prepares each action against the saved state it names.

private typealias Validator = @Sendable (JSONValue) -> Bool

private let maxActions = 20
/// Scroll amounts are wheel notches; each is delivered as its own wheel event.
private let scrollRange = -50.0...50.0
private let scrollRequirement = "a finite number between \(Int(scrollRange.lowerBound)) and \(Int(scrollRange.upperBound))"
private let waitRange = 0.0...60_000.0
private let defaultWaitMs = 1_000.0

private let actionFields: [ActionName: [String]] = [
	.press: ["ref", "find", "x", "y", "button", "clickCount", "expect"],
	.click: ["ref", "find", "x", "y", "button", "clickCount", "expect"],
	.doubleClick: ["ref", "find", "x", "y", "button", "expect"],
	.setText: ["ref", "find", "x", "y", "text", "expect"],
	.typeText: ["ref", "find", "x", "y", "text", "expect"],
	.keypress: ["ref", "find", "x", "y", "keys", "expect"],
	.scroll: ["ref", "find", "x", "y", "scrollX", "scrollY", "expect"],
	.drag: ["ref", "find", "x", "y", "path", "expect"],
	.moveMouse: ["ref", "find", "x", "y", "expect"],
	.wait: ["ms", "expect"],
]

private let requiredFields: [ActionName: [String]] = [.setText: ["text"], .typeText: ["text"], .keypress: ["keys"], .drag: ["path"]]
private let targetRequiredActions: Set<ActionName> = [.press, .click, .doubleClick, .setText, .scroll, .moveMouse]

private func finite(_ value: JSONValue) -> Double? {
	value.number.flatMap { $0.isFinite ? $0 : nil }
}

private func isPoint(_ value: JSONValue) -> Bool {
	switch value {
	case .array(let pair): return pair.count == 2 && pair.allSatisfy { finite($0) != nil }
	case .object(let members): return members.allSatisfy { $0.key == "x" || $0.key == "y" } && value["x"].flatMap(finite) != nil && value["y"].flatMap(finite) != nil
	default: return false
	}
}

private let fieldRules: [String: (valid: Validator, requirement: String)] = [
	"ref": ({ $0.string.map { !Text.trim($0).isEmpty } ?? false }, "a non-empty string"),
	"x": ({ finite($0) != nil }, "a finite number"),
	"y": ({ finite($0) != nil }, "a finite number"),
	"text": ({ $0.string != nil }, "a string"),
	"keys": ({ ($0.array.map { !$0.isEmpty && $0.allSatisfy { $0.string.map { !Text.trim($0).isEmpty } ?? false } }) ?? false }, "a non-empty array of non-empty strings"),
	"scrollX": ({ finite($0).map(scrollRange.contains) ?? false }, scrollRequirement),
	"scrollY": ({ finite($0).map(scrollRange.contains) ?? false }, scrollRequirement),
	"path": ({ ($0.array.map { $0.count >= 2 && $0.allSatisfy(isPoint) }) ?? false }, "an array of at least two finite {x,y} points or [x,y] pairs"),
	"button": ({ $0.string.flatMap(MouseButton.init(rawValue:)) != nil }, "left, right, or middle"),
	"clickCount": ({ finite($0).map { $0 == $0.rounded() && (1...3).contains($0) } ?? false }, "an integer from 1 to 3"),
	"ms": ({ finite($0).map(waitRange.contains) ?? false }, "a finite number from 0 to 60000"),
]

/// What a step may say about where to look, and about what must hold afterwards. Both are
/// checked key by key like the action's own fields, then as a whole.
private let rootRequirement = "state, opened, or app"
private let timeoutRequirement = "an integer from 0 to \(Int(waitRange.upperBound))"
private let nonEmptyString: Validator = { $0.string.map { !Text.trim($0).isEmpty } ?? false }
private let rootChoice: Validator = { $0.string.flatMap(RootChoice.init(rawValue:)) != nil }
private let wholeTimeout: Validator = { finite($0).map { $0 == $0.rounded() && waitRange.contains($0) } ?? false }

private let findRules: [String: (valid: Validator, requirement: String)] = [
	"role": (nonEmptyString, "a non-empty string"),
	"name": (nonEmptyString, "a non-empty string"),
	"nth": ({ finite($0).map { $0 == $0.rounded() && $0 >= 0 } ?? false }, "a non-negative integer"),
	"root": (rootChoice, rootRequirement),
	"timeoutMs": (wholeTimeout, timeoutRequirement),
]

private let expectRules: [String: (valid: Validator, requirement: String)] = [
	"text": (nonEmptyString, "a non-empty string"),
	"role": (nonEmptyString, "a non-empty string"),
	"value": (nonEmptyString, "a non-empty string"),
	"gone": ({ $0.bool != nil }, "true or false"),
	"timeoutMs": (wholeTimeout, timeoutRequirement),
	"root": (rootChoice, rootRequirement),
]

/// A nested object of a step: known keys only, each valid, and at least one of `required`.
private func validateObject(_ value: JSONValue, path: String, rules: [String: (valid: Validator, requirement: String)], needs: [String], needsText: String) throws {
	guard case .object(let members) = value else { throw invalid("\(path) must be an object.") }
	for (key, member) in members.sorted(by: { $0.key < $1.key }) {
		guard let rule = rules[key] else { throw invalid("\(path).\(key) is not supported.") }
		if !rule.valid(member) { throw invalid("\(path).\(key) must be \(rule.requirement).") }
	}
	if !needs.contains(where: { members[$0] != nil }) { throw invalid("\(path) needs \(needsText).") }
}

private func hasPointTarget(_ action: JSONValue) -> Bool {
	action["ref"]?.string.map { !Text.trim($0).isEmpty } == true || (action["x"].flatMap(finite) != nil && action["y"].flatMap(finite) != nil)
}

/// Fields are checked in key order, so the same item always reports the same field.
private func validateFields(_ members: [String: JSONValue], _ name: ActionName) throws {
	let allowed = actionFields[name] ?? []
	for (key, value) in members.sorted(by: { $0.key < $1.key }) where key != "action" {
		let path = "\(name.rawValue).\(key)"
		guard allowed.contains(key) else { throw invalid("\(path) is not supported.") }
		switch key {
		case "find": try validateObject(value, path: path, rules: findRules, needs: ["role", "name"], needsText: "a role or a name")
		case "expect": try validateObject(value, path: path, rules: expectRules, needs: ["text", "role", "value"], needsText: "text, role, or value")
		default:
			guard let rule = fieldRules[key] else { throw invalid("\(path) is not supported.") }
			if !rule.valid(value) { throw invalid("\(path) must be \(rule.requirement).") }
		}
	}
	let keys = Set(members.keys)
	for field in requiredFields[name] ?? [] where !keys.contains(field) { throw invalid("\(name.rawValue).\(field) is required.") }
	if keys.contains("x") != keys.contains("y") { throw invalid("\(name.rawValue).x and \(name.rawValue).y must be supplied together.") }
	if keys.contains("ref"), keys.contains("x") { throw invalid("\(name.rawValue) must use either ref or coordinates, not both.") }
	if keys.contains("find"), keys.contains("ref") { throw invalid("\(name.rawValue) must use either ref or find, not both.") }
	if keys.contains("find"), keys.contains("x") { throw invalid("\(name.rawValue) must use either find or coordinates, not both.") }
}

/// Checks the whole array before anything is delivered and returns it typed.
public func validateActions(_ values: [JSONValue]) throws -> [UiAction] {
	if values.isEmpty { throw invalid("act-ui actions must contain at least one action.") }
	if values.count > maxActions { throw invalid("act-ui supports at most \(maxActions) actions per transaction.") }
	var focusMayExist = false
	for (index, value) in values.enumerated() {
		guard case .object(let members) = value else { throw invalid("Every act-ui item must be an action object.") }
		guard let action = value["action"] else { throw invalid("Every act-ui item needs an action.") }
		guard let name = action.string.flatMap(ActionName.init(rawValue:)) else {
			throw invalid("Unsupported action '\(action.string ?? action.serialized())'.")
		}
		try validateFields(members, name)
		if index == 0, value["find"]?["root"]?.string == RootChoice.opened.rawValue {
			throw invalid("\(name.rawValue).find.root opened needs an earlier action in the array.")
		}
		let pointed = hasPointTarget(value)
		let targeted = pointed || value["find"] != nil
		if name == .typeText || name == .keypress, !targeted, !focusMayExist {
			throw invalid("\(name.rawValue) without a target requires an earlier focus-establishing action.")
		}
		if targetRequiredActions.contains(name), !targeted { throw invalid("\(name.rawValue) requires ref, find, or both x and y.") }
		// What a found element is, and so whether its click focused anything, is known only
		// when its step runs; typing after it names its own target.
		if [.press, .click, .doubleClick].contains(name), pointed { focusMayExist = true }
	}
	return try values.map { try JSONCoding.decode(UiAction.self, from: $0) }
}

// MARK: - preparation

public struct ImageSize: Codable, Sendable, Equatable {
	public var width: Int
	public var height: Int

	public init(width: Int, height: Int) {
		self.width = width
		self.height = height
	}
}

public struct Point: Codable, Sendable, Equatable {
	public var x: Double
	public var y: Double
}

public enum ActionTarget: Codable, Sendable, Equatable {
	case ref(String)
	case point(Point)
	/// The window's current keyboard focus, clicked at the image center.
	case focus(x: Int, y: Int)

	enum CodingKeys: String, CodingKey { case ref, x, y, focus }

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		if let ref = try container.decodeIfPresent(String.self, forKey: .ref) {
			self = .ref(ref)
		} else if container.contains(.focus) {
			let focus = try container.decode(Point.self, forKey: .focus)
			self = .focus(x: Int(focus.x), y: Int(focus.y))
		} else {
			self = .point(try Point(from: decoder))
		}
	}

	var isPoint: Bool {
		if case .point = self { return true }
		return false
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .ref(let ref): try container.encode(ref, forKey: .ref)
		case .point(let point): try point.encode(to: encoder)
		case .focus(let x, let y): try container.encode(Point(x: Double(x), y: Double(y)), forKey: .focus)
		}
	}
}

public enum PreparedParams: Codable, Sendable, Equatable {
	case click(button: MouseButton, clickCount: Int)
	case text(String)
	case keys([String])
	case scroll(x: Int, y: Int)
	case drag([Point])
	case none
	case wait(ms: Int)

	enum CodingKeys: String, CodingKey { case button, clickCount, text, keys, scrollX, scrollY, path, ms }

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		if let button = try container.decodeIfPresent(MouseButton.self, forKey: .button) {
			self = .click(button: button, clickCount: try container.decode(Int.self, forKey: .clickCount))
		} else if let text = try container.decodeIfPresent(String.self, forKey: .text) {
			self = .text(text)
		} else if let keys = try container.decodeIfPresent([String].self, forKey: .keys) {
			self = .keys(keys)
		} else if let x = try container.decodeIfPresent(Int.self, forKey: .scrollX) {
			self = .scroll(x: x, y: try container.decode(Int.self, forKey: .scrollY))
		} else if let path = try container.decodeIfPresent([Point].self, forKey: .path) {
			self = .drag(path)
		} else if let ms = try container.decodeIfPresent(Int.self, forKey: .ms) {
			self = .wait(ms: ms)
		} else {
			self = .none
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .click(let button, let clickCount):
			try container.encode(button, forKey: .button)
			try container.encode(clickCount, forKey: .clickCount)
		case .text(let text): try container.encode(text, forKey: .text)
		case .keys(let keys): try container.encode(keys, forKey: .keys)
		case .scroll(let x, let y):
			try container.encode(x, forKey: .scrollX)
			try container.encode(y, forKey: .scrollY)
		case .drag(let path): try container.encode(path, forKey: .path)
		case .none: break
		case .wait(let ms): try container.encode(ms, forKey: .ms)
		}
	}
}

/// One action ready for delivery. `doubleClick` becomes a click with two clicks; `wait` has no target.
public struct PreparedAction: Codable, Sendable, Equatable {
	public var action: ActionName
	public var target: ActionTarget?
	public var params: PreparedParams
	/// A click that put keyboard focus somewhere later untargeted typing may use: into an
	/// editable element, or wherever a click delivered at coordinates landed (OCR text, a node
	/// without an accessibility element, an x/y click), where the platform cannot say.
	public var establishesFocus: Bool
}

public struct ActionState: Sendable {
	public var currentFocus: Bool

	public init(currentFocus: Bool) {
		self.currentFocus = currentFocus
	}
}

/// Semantic actions are delivered to the element that owns the capability the view promised.
let ownedCapabilities: [ActionName: [Capability]] = [
	.press: [.press, .toggle, .open],
	.click: [.press, .toggle, .open],
	.doubleClick: [.press, .toggle, .open],
	.setText: [.setText],
	.typeText: [.typeText],
	.scroll: [.scroll],
]

/// The saved state an action runs against: its outline, the capability owners of its view,
/// and the image coordinates are measured in.
public struct ActionEnvironment {
	public let outline: Outline
	public let image: ImageSize?
	public let headless: Bool
	private let owners: [String: [String: String]]

	public init(outline: Outline, image: ImageSize?, headless: Bool) {
		self.outline = outline
		self.image = image
		self.headless = headless
		var owners: [String: [String: String]] = [:]
		for node in project(outline, .unfolded).nodes { owners[node.ref] = node.owners }
		self.owners = owners
	}

	func node(_ ref: String, for action: ActionName) throws -> OutlineNode {
		let owner = (ownedCapabilities[action] ?? []).lazy.compactMap { self.owners[ref]?[$0.rawValue] }.first
		let resolved = owner ?? ref
		guard let node = outline.node(resolved) else {
			throw BCUError(.elementNotFound, "Ref '\(resolved)' does not belong to the current state. Observe the root again and use a ref from the new state.")
		}
		return node
	}

	func center(_ node: OutlineNode) throws -> Point {
		guard let rect = node.rect else { throw BCUError(.elementNotFound, "Ref '\(node.ref)' has no coordinates in the current state. Observe the root again.") }
		return Point(x: rect.x + rect.w / 2, y: rect.y + rect.h / 2)
	}

	func validate(_ point: Point, label: String = "Coordinates") throws {
		guard let image else { throw invalid("\(label) require an image-bearing state. Observe with --image always, or act on a ref.") }
		guard point.x.isFinite, point.y.isFinite else { throw invalid("\(label) must be finite numbers.") }
		if point.x < 0 || point.y < 0 || point.x >= Double(image.width) || point.y >= Double(image.height) {
			let shown = "\(Text.number(point.x.rounded())),\(Text.number(point.y.rounded()))"
			throw invalid("\(label) (\(shown)) are outside the image bounds (\(image.width)x\(image.height)).")
		}
	}
}

private func dragPath(_ points: [PathPoint], _ environment: ActionEnvironment) throws -> [Point] {
	try points.enumerated().map { index, point in
		let resolved = Point(x: point.x, y: point.y)
		try environment.validate(resolved, label: "Drag point \(index + 1)")
		return resolved
	}
}

private func nativeTarget(_ action: UiAction, _ operation: ActionName, _ environment: ActionEnvironment) throws -> ActionTarget {
	if let ref = Text.trimmedOrNil(action.ref) {
		let node = try environment.node(ref, for: action.action)
		let semanticClick = operation == .click || operation == .press
		let onlyIncidental = node.actions.allSatisfy { $0 == "AXShowMenu" || $0 == "AXScrollToVisible" }
		if let wireRef = node.wireRef, !wireRef.isEmpty, !node.pictureOnly,
		   !semanticClick || node.canPress || node.canFocus || node.canSetValue || !onlyIncidental {
			return .ref(wireRef)
		}
		let point = try environment.center(node)
		try environment.validate(point)
		return .point(point)
	}
	if let x = action.x, let y = action.y, x.isFinite, y.isFinite {
		let point = Point(x: x, y: y)
		try environment.validate(point)
		return .point(point)
	}
	if operation == .drag, let path = action.path, !path.isEmpty { return .point(try dragPath(path, environment)[0]) }
	throw invalid("\(operation.rawValue) requires ref, find, or both x and y.")
}

private func focusedTarget(_ environment: ActionEnvironment) throws -> ActionTarget {
	guard let image = environment.image else {
		throw BCUError(.actionFailed, "Focused keyboard input requires an image-bearing state. Observe with --image always and retry.")
	}
	return .focus(x: image.width / 2, y: image.height / 2)
}

private func containsEditable(_ node: OutlineNode) -> Bool {
	node.canSetValue || node.role.lowercased().contains("text") || node.children.contains(where: containsEditable)
}

public func prepareAction(_ action: UiAction, state: ActionState, environment: ActionEnvironment) throws -> PreparedAction {
	if action.action == .wait {
		return PreparedAction(action: .wait, params: .wait(ms: Int((action.ms ?? defaultWaitMs).rounded())), establishesFocus: false)
	}
	let operation = action.action == .doubleClick ? .click : action.action
	let ref = action.ref ?? ""
	let intoCurrentFocus = !environment.headless && state.currentFocus && ref.isEmpty && (operation == .typeText || operation == .keypress)
	let target = intoCurrentFocus ? try focusedTarget(environment) : try nativeTarget(action, operation, environment)
	let establishesFocus = try !environment.headless && (operation == .click || operation == .press) && (target.isPoint || !ref.isEmpty && containsEditable(environment.node(ref, for: action.action)))
	let params: PreparedParams = switch operation {
	case .press, .click: .click(button: action.button ?? .left, clickCount: action.action == .doubleClick ? 2 : action.clickCount ?? 1)
	case .setText, .typeText: .text(action.text ?? "")
	case .keypress: .keys(action.keys ?? [])
	case .scroll: .scroll(x: Int((action.scrollX ?? 0).rounded()), y: Int((action.scrollY ?? 0).rounded()))
	case .drag: .drag(try dragPath(action.path ?? [], environment))
	case .moveMouse, .doubleClick, .wait: .none
	}
	return PreparedAction(
		action: operation, target: target, params: params,
		establishesFocus: establishesFocus
	)
}

// MARK: - outcomes

public enum CheckResult: String, Codable, Sendable {
	case verified, preexisting, failed
}

/// The delivery ladder moves up only past a rung that provably changed nothing (`didnt`) or
/// that the platform refuses as needing the foreground. `unknown` stays put: the rung
/// delivered, and repeating it could apply the action twice.
public func canRetryInForeground(_ outcome: ActOutcome, headless: Bool) -> Bool {
	!headless && outcome == .didnt
}

public func outcomeAfterCheck(_ current: ActOutcome, _ check: CheckResult) -> ActOutcome {
	switch check {
	case .verified: .worked
	case .failed: .didnt
	case .preexisting: current
	}
}

/// setText-only transactions are proven by the values the successor state reads back.
public func outcomeAfterObservedValues(_ current: ActOutcome, actions: [UiAction], valueForRef: (String) -> String?) -> ActOutcome {
	let meaningful = actions.filter { $0.action != .wait }
	if meaningful.isEmpty || meaningful.contains(where: { $0.action != .setText || ($0.ref ?? "").isEmpty }) { return current }
	return meaningful.allSatisfy { valueForRef($0.ref!) == ($0.text ?? "") } ? .worked : current
}
