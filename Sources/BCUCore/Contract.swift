/// Command parameters and results. Each type is the one definition shared by the CLI, the
/// resident process and the wire between them; property order is the JSON key order.

public enum RootKind: String, Codable, Sendable, CaseIterable {
	case window, menubar, menu, sheet, popover, dialog
}

public enum ImageMode: String, Codable, Sendable, CaseIterable {
	case never, always
}

public enum ObserveMode: String, Codable, Sendable, CaseIterable {
	case semantic, fused
}

public enum ReadTextMode: String, Codable, Sendable, CaseIterable {
	case auto, always, never
}

public enum MouseButton: String, Codable, Sendable, CaseIterable {
	case left, right, middle
}

// MARK: - parameters

public struct FindParams: Codable, Sendable, Equatable {
	public var query: String?
	public var app: String?
	public var bundleId: String?
	public var pid: Int?
	/// Filters on the platform's best-effort presentation hint; only window vs transient is guaranteed.
	public var kind: RootKind?
}

public struct ObserveParams: Codable, Sendable, Equatable {
	public var app: String?
	public var windowTitle: String?
	/// An `@r` ref from find-roots, or a numeric window id.
	public var root: String?
	public var mode: ObserveMode?
	public var image: ImageMode?
	public var readText: ReadTextMode?
}

public struct SearchUiParams: Codable, Sendable, Equatable {
	public var stateId: String
	public var text: String?
	public var role: String?
	public var action: String?
	public var limit: Int?
}

public struct ExpandUiParams: Codable, Sendable, Equatable {
	public var stateId: String
	public var ref: String
	public var depth: Int?
}

public struct InspectUiParams: Codable, Sendable, Equatable {
	public var stateId: String
	public var ref: String
}

public enum ActionName: String, Codable, Sendable, CaseIterable {
	case press, click, doubleClick, setText, typeText, keypress, scroll, drag, moveMouse, wait
}

/// A drag point, in the form the caller wrote it.
public enum PathPoint: Codable, Sendable, Equatable {
	case object(x: Double, y: Double)
	case pair(Double, Double)

	public var x: Double {
		switch self {
		case .object(let x, _), .pair(let x, _): x
		}
	}

	public var y: Double {
		switch self {
		case .object(_, let y), .pair(_, let y): y
		}
	}

	enum CodingKeys: String, CodingKey { case x, y }

	public init(from decoder: any Decoder) throws {
		if var pair = try? decoder.unkeyedContainer() {
			self = .pair(try pair.decode(Double.self), try pair.decode(Double.self))
		} else {
			let point = try decoder.container(keyedBy: CodingKeys.self)
			self = .object(x: try point.decode(Double.self, forKey: .x), y: try point.decode(Double.self, forKey: .y))
		}
	}

	public func encode(to encoder: any Encoder) throws {
		switch self {
		case .object(let x, let y):
			var point = encoder.container(keyedBy: CodingKeys.self)
			try point.encode(x, forKey: .x)
			try point.encode(y, forKey: .y)
		case .pair(let x, let y):
			var pair = encoder.unkeyedContainer()
			try pair.encode(x)
			try pair.encode(y)
		}
	}
}

public struct UiAction: Codable, Sendable, Equatable {
	public var action: ActionName
	public var ref: String?
	public var x: Double?
	public var y: Double?
	public var text: String?
	public var keys: [String]?
	public var scrollX: Double?
	public var scrollY: Double?
	public var path: [PathPoint]?
	public var button: MouseButton?
	public var clickCount: Int?
	public var ms: Double?
}

/// Semantic postcondition; `scope` limits it to one element subtree.
public struct Expectation: Codable, Sendable, Equatable {
	public var text: String?
	public var role: String?
	public var value: String?
	public var scope: String?
	public var gone: Bool?
	public var timeoutMs: Int?
}

public struct ActParams: Codable, Sendable, Equatable {
	public var stateId: String
	public var actions: [UiAction]
	/// Prohibits foreground fallback when true. Background is always attempted first.
	public var headless: Bool?
	public var image: ImageMode?
	public var expect: Expectation?
}

public struct ReadTextParams: Codable, Sendable, Equatable {
	public var stateId: String
	public var ref: String
	public var offset: Int?
	public var limit: Int?
}

public struct WaitForParams: Codable, Sendable, Equatable {
	public var stateId: String
	public var text: String?
	public var role: String?
	public var scope: String?
	public var gone: Bool?
	public var timeoutMs: Int?
}

// MARK: - results

public struct Frame: Codable, Sendable, Equatable {
	public var x: Double
	public var y: Double
	public var w: Double
	public var h: Double
}

public struct ImageInfo: Codable, Sendable, Equatable {
	public var path: String
	public var mime: String
	public var width: Int
	public var height: Int
}

public struct RootInfo: Codable, Sendable, Equatable {
	public var ref: String
	public var app: String
	public var bundleId: String?
	public var pid: Int
	public var title: String
	public var windowId: Int?
	public var kind: RootKind
	public var frame: Frame
	public var focused: Bool
	public var main: Bool
	public var onscreen: Bool
	public var minimized: Bool
	public var modal: Bool
}

public struct FindRootsResult: Codable, Sendable, Equatable {
	public var roots: [RootInfo]
}

/// A root an action brought into existence, ready to observe by `ref`.
public struct RootAppearance: Codable, Sendable, Equatable {
	public var ref: String
	public var kind: RootKind
	public var app: String
	public var title: String
}

public struct RootSummary: Codable, Sendable, Equatable {
	public var ref: String?
	public var app: String
	public var pid: Int
	public var title: String
	public var windowId: Int?
	public var frame: Frame
	public var scale: Double
}

public struct ObserveResult: Codable, Sendable, Equatable {
	public var stateId: String
	public var root: RootSummary
	public var nodes: [ProjectedNode]
	public var shown: Int
	public var total: Int
	public var image: ImageInfo?
}

/// A projected node with its projected ancestry, outermost first.
public struct SearchMatch: Codable, Sendable, Equatable {
	public var node: ProjectedNode
	public var path: [String]

	enum CodingKeys: String, CodingKey { case path }

	public init(node: ProjectedNode, path: [String]) {
		self.node = node
		self.path = path
	}

	public init(from decoder: any Decoder) throws {
		node = try ProjectedNode(from: decoder)
		path = try decoder.container(keyedBy: CodingKeys.self).decode([String].self, forKey: .path)
	}

	public func encode(to encoder: any Encoder) throws {
		try node.encode(to: encoder)
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(path, forKey: .path)
	}
}

public struct SearchResult: Codable, Sendable, Equatable {
	public var stateId: String
	public var matches: [SearchMatch]
	public var total: Int
}

public struct ExpandResult: Codable, Sendable, Equatable {
	public var stateId: String
	public var ref: String
	public var nodes: [ProjectedNode]
}

public struct InspectResult: Codable, Sendable, Equatable {
	public var stateId: String
	public var node: SerializedOutlineNode
	/// Capabilities this ref advertises that another element performs.
	public var owners: OrderedMap<String>?
}

public struct ReadTextResult: Codable, Sendable, Equatable {
	public var stateId: String
	public var ref: String
	public var offset: Int
	public var limit: Int
	public var total: Int
	public var text: String
}

public struct WaitForResult: Codable, Sendable, Equatable {
	public var stateId: String
	public var found: Bool
	public var gone: Bool?
	public var changes: [Change]?
	public var offscreen: OffscreenChanges?
	public var nodes: [ProjectedNode]?
	public var shown: Int?
	public var total: Int?
}

public enum ActOutcome: String, Codable, Sendable {
	/// `unknown`: delivered, but no evidence could judge it; rendered as `unverified`.
	case worked, didnt, unknown
}

/// Why an action was called landed: the element fact that moved, the root forest changing,
/// the pointer reaching an element that then held focus, or the screen changing.
public struct ActEvidence: Codable, Sendable, Equatable {
	public enum Source: String, Codable, Sendable { case ax, root, focus, screen }
	public enum Field: String, Codable, Sendable { case value, selected, focused, selection, selectedText, scroll, changed, closed }

	public var source: Source
	/// `closed` with source `root`: the root the action ran in is gone.
	public var field: Field?
	public var from: String?
	public var to: String?
}

public struct Verification: Codable, Sendable, Equatable {
	public enum Status: String, Codable, Sendable { case verified, none }

	public var status: Status
	/// The platform's own reason for the outcome, independent of any expectation.
	public var evidence: ActEvidence?
	public var text: String?
	public var role: String?
	public var value: String?
	public var scope: String?
	public var gone: Bool?
	public var timeoutMs: Int?
	/// True when the expectation already held before the transaction ran.
	public var preexisting: Bool?
}

/// The root the actions ran in closed; `skipped` later steps were not sent to it.
public struct ClosedRoot: Codable, Sendable, Equatable {
	public var root: RootAppearance
	public var skipped: Int?
}

public struct ActResult: Codable, Sendable, Equatable {
	/// Absent only when the action closed the app's last root and there is nothing to observe.
	public var stateId: String?
	public var baseStateId: String
	/// `worked` or `unknown`; a proven no-op is an `action_failed` error instead.
	public var outcome: ActOutcome
	public var verification: Verification
	public var delivery: String
	/// Roots the transaction opened: menus, sheets, dialogs and new windows.
	public var roots: [RootAppearance]?
	public var closed: ClosedRoot?
	/// After a closed root: the app's root the successor state observes.
	public var next: RootAppearance?
	public var changes: [Change]?
	public var offscreen: OffscreenChanges?
	public var nodes: [ProjectedNode]?
	public var shown: Int?
	public var total: Int?
	public var image: ImageInfo?
}

// MARK: - commands

public enum CommandName: String, Codable, Sendable, CaseIterable {
	case findRoots = "find-roots"
	case observeUi = "observe-ui"
	case searchUi = "search-ui"
	case expandUi = "expand-ui"
	case inspectUi = "inspect-ui"
	case actUi = "act-ui"
	case readText = "read-text"
	case waitFor = "wait-for"
}

/// One command as the CLI sends it: `{command, params}`.
public enum CommandRequest: Codable, Sendable, Equatable {
	case findRoots(FindParams)
	case observeUi(ObserveParams)
	case searchUi(SearchUiParams)
	case expandUi(ExpandUiParams)
	case inspectUi(InspectUiParams)
	case actUi(ActParams)
	case readText(ReadTextParams)
	case waitFor(WaitForParams)

	public var name: CommandName {
		switch self {
		case .findRoots: .findRoots
		case .observeUi: .observeUi
		case .searchUi: .searchUi
		case .expandUi: .expandUi
		case .inspectUi: .inspectUi
		case .actUi: .actUi
		case .readText: .readText
		case .waitFor: .waitFor
		}
	}

	enum CodingKeys: String, CodingKey { case command, params }

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		switch try container.decode(CommandName.self, forKey: .command) {
		case .findRoots: self = .findRoots(try container.decode(FindParams.self, forKey: .params))
		case .observeUi: self = .observeUi(try container.decode(ObserveParams.self, forKey: .params))
		case .searchUi: self = .searchUi(try container.decode(SearchUiParams.self, forKey: .params))
		case .expandUi: self = .expandUi(try container.decode(ExpandUiParams.self, forKey: .params))
		case .inspectUi: self = .inspectUi(try container.decode(InspectUiParams.self, forKey: .params))
		case .actUi: self = .actUi(try container.decode(ActParams.self, forKey: .params))
		case .readText: self = .readText(try container.decode(ReadTextParams.self, forKey: .params))
		case .waitFor: self = .waitFor(try container.decode(WaitForParams.self, forKey: .params))
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(name, forKey: .command)
		switch self {
		case .findRoots(let params): try container.encode(params, forKey: .params)
		case .observeUi(let params): try container.encode(params, forKey: .params)
		case .searchUi(let params): try container.encode(params, forKey: .params)
		case .expandUi(let params): try container.encode(params, forKey: .params)
		case .inspectUi(let params): try container.encode(params, forKey: .params)
		case .actUi(let params): try container.encode(params, forKey: .params)
		case .readText(let params): try container.encode(params, forKey: .params)
		case .waitFor(let params): try container.encode(params, forKey: .params)
		}
	}
}

/// One command's result; its JSON is the result object itself.
public enum CommandResult: Sendable, Equatable {
	case findRoots(FindRootsResult)
	case observeUi(ObserveResult)
	case searchUi(SearchResult)
	case expandUi(ExpandResult)
	case inspectUi(InspectResult)
	case actUi(ActResult)
	case readText(ReadTextResult)
	case waitFor(WaitForResult)

	public static func decode(_ name: CommandName, from value: JSONValue) throws -> CommandResult {
		switch name {
		case .findRoots: .findRoots(try JSONCoding.decode(FindRootsResult.self, from: value))
		case .observeUi: .observeUi(try JSONCoding.decode(ObserveResult.self, from: value))
		case .searchUi: .searchUi(try JSONCoding.decode(SearchResult.self, from: value))
		case .expandUi: .expandUi(try JSONCoding.decode(ExpandResult.self, from: value))
		case .inspectUi: .inspectUi(try JSONCoding.decode(InspectResult.self, from: value))
		case .actUi: .actUi(try JSONCoding.decode(ActResult.self, from: value))
		case .readText: .readText(try JSONCoding.decode(ReadTextResult.self, from: value))
		case .waitFor: .waitFor(try JSONCoding.decode(WaitForResult.self, from: value))
		}
	}

	public func json() throws -> JSONValue {
		switch self {
		case .findRoots(let result): try JSONCoding.encode(result)
		case .observeUi(let result): try JSONCoding.encode(result)
		case .searchUi(let result): try JSONCoding.encode(result)
		case .expandUi(let result): try JSONCoding.encode(result)
		case .inspectUi(let result): try JSONCoding.encode(result)
		case .actUi(let result): try JSONCoding.encode(result)
		case .readText(let result): try JSONCoding.encode(result)
		case .waitFor(let result): try JSONCoding.encode(result)
		}
	}
}
