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

/// Which root of the app a step looks in: the root of the state being acted on, the root the
/// array's earlier steps opened most recently, or the root the app would be observed at now.
public enum RootChoice: String, Codable, Sendable, CaseIterable {
	case state, opened, app
}

/// An element named by what the view shows, found in a fresh observation when its step runs.
/// `nth` counts from 0 among the candidates a failure lists.
public struct Locator: Codable, Sendable, Equatable {
	public var role: String?
	public var name: String?
	public var nth: Int?
	/// The root to look in; the state's own root when absent.
	public var root: RootChoice?
	/// How long to wait for a match to appear (default 3000).
	public var timeoutMs: Int?
}

public struct UiAction: Codable, Sendable, Equatable {
	public var action: ActionName
	public var ref: String?
	public var find: Locator?
	/// A condition checked right after this step, before the next one runs.
	public var expect: Expectation?
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

/// Semantic postcondition; `scope` limits it to one element subtree. On a step, `root` names
/// where to check (the step's own root when absent) and `scope` is not allowed.
public struct Expectation: Codable, Sendable, Equatable {
	public var text: String?
	public var role: String?
	public var value: String?
	public var scope: String?
	public var gone: Bool?
	public var timeoutMs: Int?
	public var root: RootChoice?
}

public struct ActParams: Codable, Sendable, Equatable {
	public var stateId: String
	public var actions: [UiAction]
	/// Prohibits foreground fallback when true. Background is always attempted first.
	public var headless: Bool?
	/// Starts the ladder at the foreground rung: the caller knows the app only reacts while
	/// it is the front app, which bcu cannot tell from the outside.
	public var foreground: Bool?
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

	public init(x: Double, y: Double, w: Double, h: Double) {
		self.x = x
		self.y = y
		self.w = w
		self.h = h
	}
}

public struct ImageInfo: Codable, Sendable, Equatable {
	public var path: String
	public var mime: String
	public var width: Int
	public var height: Int

	public init(path: String, mime: String, width: Int, height: Int) {
		self.path = path
		self.mime = mime
		self.width = width
		self.height = height
	}
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

	public init(ref: String, app: String, bundleId: String? = nil, pid: Int, title: String, windowId: Int? = nil, kind: RootKind, frame: Frame, focused: Bool, main: Bool, onscreen: Bool, minimized: Bool, modal: Bool) {
		self.ref = ref
		self.app = app
		self.bundleId = bundleId
		self.pid = pid
		self.title = title
		self.windowId = windowId
		self.kind = kind
		self.frame = frame
		self.focused = focused
		self.main = main
		self.onscreen = onscreen
		self.minimized = minimized
		self.modal = modal
	}
}

public struct FindRootsResult: Codable, Sendable, Equatable {
	public var roots: [RootInfo]

	public init(roots: [RootInfo]) {
		self.roots = roots
	}
}

/// A root an action brought into existence, ready to observe by `ref`.
public struct RootAppearance: Codable, Sendable, Equatable {
	public var ref: String
	public var kind: RootKind
	public var app: String
	public var title: String

	public init(ref: String, kind: RootKind, app: String, title: String) {
		self.ref = ref
		self.kind = kind
		self.app = app
		self.title = title
	}
}

public struct RootSummary: Codable, Sendable, Equatable {
	public var ref: String?
	public var app: String
	public var pid: Int
	public var title: String
	public var windowId: Int?
	public var frame: Frame
	public var scale: Double

	public init(ref: String? = nil, app: String, pid: Int, title: String, windowId: Int? = nil, frame: Frame, scale: Double) {
		self.ref = ref
		self.app = app
		self.pid = pid
		self.title = title
		self.windowId = windowId
		self.frame = frame
		self.scale = scale
	}
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
	public var owners: [String: String]?
}

public struct ReadTextResult: Codable, Sendable, Equatable {
	public var stateId: String
	public var ref: String
	public var offset: Int
	public var limit: Int
	public var total: Int
	public var text: String

	public init(stateId: String, ref: String, offset: Int, limit: Int, total: Int, text: String) {
		self.stateId = stateId
		self.ref = ref
		self.offset = offset
		self.limit = limit
		self.total = total
		self.text = text
	}
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

	public init(stateId: String, found: Bool, gone: Bool? = nil, changes: [Change]? = nil, offscreen: OffscreenChanges? = nil, nodes: [ProjectedNode]? = nil, shown: Int? = nil, total: Int? = nil) {
		self.stateId = stateId
		self.found = found
		self.gone = gone
		self.changes = changes
		self.offscreen = offscreen
		self.nodes = nodes
		self.shown = shown
		self.total = total
	}
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

	public init(source: Source, field: Field? = nil, from: String? = nil, to: String? = nil) {
		self.source = source
		self.field = field
		self.from = from
		self.to = to
	}
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

	public init(status: Status, evidence: ActEvidence? = nil, text: String? = nil, role: String? = nil, value: String? = nil, scope: String? = nil, gone: Bool? = nil, timeoutMs: Int? = nil, preexisting: Bool? = nil) {
		self.status = status
		self.evidence = evidence
		self.text = text
		self.role = role
		self.value = value
		self.scope = scope
		self.gone = gone
		self.timeoutMs = timeoutMs
		self.preexisting = preexisting
	}
}

/// A root an action opened, observed right away: `stateId` and the refs in `nodes` go straight
/// into the next act-ui, exactly as if observe-ui had been run on `root`.
public struct OpenedRoot: Codable, Sendable, Equatable {
	public var root: RootAppearance
	public var stateId: String
	public var nodes: [ProjectedNode]
	public var shown: Int
	public var total: Int

	public init(root: RootAppearance, stateId: String, nodes: [ProjectedNode], shown: Int, total: Int) {
		self.root = root
		self.stateId = stateId
		self.nodes = nodes
		self.shown = shown
		self.total = total
	}
}

public struct ActResult: Codable, Sendable, Equatable {
	/// Observes the state's own root, or `next` when it is gone. Absent only when the app has
	/// no root left to observe.
	public var stateId: String?
	public var baseStateId: String
	/// `worked` or `unknown`; a proven no-op is an `action_failed` error instead.
	public var outcome: ActOutcome
	public var verification: Verification
	public var delivery: String
	/// Roots the transaction opened: menus, sheets, dialogs and new windows.
	public var roots: [RootAppearance]?
	/// Roots the actions acted in, or the state's own root, that are gone now.
	public var closed: [RootAppearance]?
	/// The root the successor state observes when it is not the state's own: the one the app
	/// would be observed at now.
	public var next: RootAppearance?
	/// One of `roots` with its view attached: a menu, sheet, popover or dialog the actions
	/// opened and left open.
	public var opened: OpenedRoot?
	public var changes: [Change]?
	public var offscreen: OffscreenChanges?
	public var nodes: [ProjectedNode]?
	public var shown: Int?
	public var total: Int?
	public var image: ImageInfo?

	public init(stateId: String? = nil, baseStateId: String, outcome: ActOutcome, verification: Verification, delivery: String, roots: [RootAppearance]? = nil, closed: [RootAppearance]? = nil, next: RootAppearance? = nil, opened: OpenedRoot? = nil, changes: [Change]? = nil, offscreen: OffscreenChanges? = nil, nodes: [ProjectedNode]? = nil, shown: Int? = nil, total: Int? = nil, image: ImageInfo? = nil) {
		self.stateId = stateId
		self.baseStateId = baseStateId
		self.outcome = outcome
		self.verification = verification
		self.delivery = delivery
		self.roots = roots
		self.closed = closed
		self.next = next
		self.opened = opened
		self.changes = changes
		self.offscreen = offscreen
		self.nodes = nodes
		self.shown = shown
		self.total = total
		self.image = image
	}
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
public enum CommandResult: Encodable, Sendable, Equatable {
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

	public func encode(to encoder: any Encoder) throws {
		switch self {
		case .findRoots(let result): try result.encode(to: encoder)
		case .observeUi(let result): try result.encode(to: encoder)
		case .searchUi(let result): try result.encode(to: encoder)
		case .expandUi(let result): try result.encode(to: encoder)
		case .inspectUi(let result): try result.encode(to: encoder)
		case .actUi(let result): try result.encode(to: encoder)
		case .readText(let result): try result.encode(to: encoder)
		case .waitFor(let result): try result.encode(to: encoder)
		}
	}

	public func json() throws -> JSONValue {
		try JSONCoding.encode(self)
	}
}
