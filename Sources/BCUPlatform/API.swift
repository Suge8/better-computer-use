import AppKit

// Request and result types of the Platform API. The helper wire protocol is one encoding
// of them (WireProtocol.swift); an in-process caller uses them directly.

public struct PlatformError: Error {
	public let message: String
	/// Stable failure code; the Broker maps it to a public CLI error code.
	public let code: String

	public init(message: String, code: String) {
		self.message = message
		self.code = code
	}
}

// MARK: Diagnostics and permissions

public struct Diagnostics {
	public let accessibility: Bool
	public let screenRecording: Bool
	public let pid: Int32
	public let parentPid: Int32
	public let parentPath: String?
	public let parentAppName: String?
	public let parentBundleId: String?
	public let executablePath: String
	public let macOS: String
	public let arch: String
}

/// Which TCC identity the permission booleans reflect.
public enum PermissionAttribution: String {
	/// The installed bundle launched through LaunchServices: grants belong to bcu.app.
	case helperApp = "helper-app"
	/// Anything else: the booleans reflect whatever app spawned this process.
	case caller
}

public struct PermissionSource {
	public let pid: Int32
	public let parentPid: Int32
	public let parentPath: String?
	public let parentBundleId: String?
	public let executablePath: String
	public let macOS: String
	public let attribution: PermissionAttribution
}

public struct PermissionStatus {
	public let accessibility: Bool
	/// The live ScreenCaptureKit probe; the authoritative Screen Recording answer.
	public let screenRecording: Bool
	/// The per-process preflight cache, kept to diagnose a stale or foreign grant.
	public let screenRecordingPreflight: Bool
	public let source: PermissionSource
}

public struct PermissionRegistration {
	public let accessibility: Bool
	public let screenRecording: Bool
}

// MARK: Apps and roots

public struct RunningApp {
	public let appName: String
	public let pid: Int32
	public let bundleId: String?
	public let isFrontmost: Bool
}

public enum RootKind: String {
	case window, sheet, dialog, popover, menu, menubar
}

public enum PairingConfidence: String {
	case exact, high, low
}

/// How surely an accessibility root was matched to a window-server window.
public struct RootPairing {
	public let confidence: PairingConfidence
	public let score: Double
}

public struct RootMetadata {
	public let pairing: RootPairing
	public let sheetCount: Int
}

public struct Root {
	public let kind: RootKind
	/// Stable handle for the root in this process; `cgmenu:<windowId>` for a popup menu that
	/// Accessibility never exposed.
	public let rootRef: String
	/// Quartz window id, absent for roots the window server does not expose separately.
	public let windowId: UInt32?
	public let zOrder: Int
	public let title: String
	public let role: String
	public let subrole: String
	public let isModal: Bool
	public let framePoints: CGRect
	public let scaleFactor: Double
	public let isMinimized: Bool
	public let isOnscreen: Bool
	public let isMain: Bool
	public let isFocused: Bool
	/// Absent on menu bars, which pair with no window.
	public let metadata: RootMetadata?
	public let pid: Int32
	public let appName: String
	public let bundleId: String?
}

/// A root that a single call addresses: `rootRef` wins over `windowId`, and neither picks
/// the app's first window.
public struct RootTarget {
	public let pid: Int32
	public let windowId: UInt32?
	public let rootRef: String?

	public init(pid: Int32, windowId: UInt32? = nil, rootRef: String? = nil) {
		self.pid = pid
		self.windowId = windowId
		self.rootRef = rootRef
	}
}

public struct Frontmost {
	public let appName: String
	public let pid: Int32
	public let bundleId: String?
	/// The app's most prominent window, when it has one.
	public let window: Root?
}

public struct FocusWindowResult {
	public let focused: Bool
	public let alreadyFocused: Bool
	/// Which AX writes succeeded; nil when the window was already focused or not found.
	public let setMain: Bool?
	public let setFocused: Bool?
	public let raised: Bool?
	/// `window_not_found` or `focus_failed`.
	public let reason: String?
}

// MARK: Look

public enum ReadTextMode: String {
	case auto, always, never
}

public struct LookRequest {
	public let rootRef: String
	public let windowId: UInt32?
	public let maxDimension: Int?
	public let readText: ReadTextMode
	/// The look this one refreshes; its geometry keeps coordinates stable across the pair.
	public let baseLookId: String?
	public let includeImage: Bool
	public let scopeRef: String?

	public init(rootRef: String, windowId: UInt32? = nil, maxDimension: Int? = nil, readText: ReadTextMode = .auto, baseLookId: String? = nil, includeImage: Bool = true, scopeRef: String? = nil) {
		self.rootRef = rootRef
		self.windowId = windowId
		self.maxDimension = maxDimension
		self.readText = readText
		self.baseLookId = baseLookId
		self.includeImage = includeImage
		self.scopeRef = scopeRef
	}
}

public struct LookWindow {
	public let windowId: UInt32
	public let rootRef: String
	public let kind: RootKind
	public let framePoints: CGRect
	public let scaleFactor: Double
	public let isModal: Bool
	public let metadata: RootMetadata
	public let role: String
	public let subrole: String
}

public struct LookTimings {
	public let captureMs: Int
	public let describeMs: Int
	public let readTextMs: Int
}

public struct LookImage {
	public let jpeg: Data
	public let width: Int
	public let height: Int
}

public struct LookResult {
	public let lookId: String
	public let capturedAt: Date
	public let window: LookWindow
	public let outline: LookNode
	public let timings: LookTimings
	/// Whether the screen was read; nil for a picture-only popup menu.
	public let readText: (requested: ReadTextMode, executed: Bool)?
	public let image: LookImage?
}

// MARK: Act

public enum ActAction: String {
	case press, click, moveMouse, scroll, drag, setText, typeText, keypress
}

public enum ActTarget {
	/// An element ref of the look.
	case ref(String)
	/// A point in the look's image coordinates.
	case point(x: Double, y: Double)
}

/// The rung of the delivery ladder a call may start from; see docs/architecture.md.
public enum ActPolicy: String {
	case `default`, background, foreground
	case axOnly = "ax_only"
}

public struct ActParams {
	public let button: CGMouseButton
	public let clickCount: Int
	public let scrollX: Int
	public let scrollY: Int
	/// Drag points in the look's image coordinates.
	public let path: [CGPoint]?
	public let text: String
	public let keys: [String]
	/// Deliver to the element's current focus instead of focusing the target first.
	public let preserveFocus: Bool
	/// Post raw input to the process rather than through the HID event stream.
	public let pidDelivery: Bool

	public init(button: CGMouseButton = .left, clickCount: Int = 1, scrollX: Int = 0, scrollY: Int = 0, path: [CGPoint]? = nil, text: String = "", keys: [String] = [], preserveFocus: Bool = false, pidDelivery: Bool = false) {
		self.button = button
		self.clickCount = clickCount
		self.scrollX = scrollX
		self.scrollY = scrollY
		self.path = path
		self.text = text
		self.keys = keys
		self.preserveFocus = preserveFocus
		self.pidDelivery = pidDelivery
	}
}

public struct ActRequest {
	public let lookId: String
	public let pid: Int32
	public let action: ActAction
	public let target: ActTarget
	public let params: ActParams
	public let policy: ActPolicy
	/// Animate the agent cursor over pointer actions delivered in the background.
	public let cursorOverlay: Bool

	public init(lookId: String, pid: Int32, action: ActAction, target: ActTarget, params: ActParams = ActParams(), policy: ActPolicy = .default, cursorOverlay: Bool = true) {
		self.lookId = lookId
		self.pid = pid
		self.action = action
		self.target = target
		self.params = params
		self.policy = policy
		self.cursorOverlay = cursorOverlay
	}
}

public enum ActOutcome: String {
	case worked, didnt, unknown
}

public enum Delivery: String {
	case ax, pid, hid
}

public enum Grounding: String {
	case description, coordinates
}

/// Where the root change of an action was first noticed.
public enum DeltaSource: String {
	case snapshot, events
	case cgPoll = "cg-poll"
}

/// What the helper did to deliver an action, beyond the action itself.
public struct ActPerformed {
	public internal(set) var delivery: Delivery
	public internal(set) var grounding: Grounding?
	/// The ref was stale and the element was found again by its identity.
	public internal(set) var refound = false
	/// The target window was made key without raising it.
	public internal(set) var focusedWindow = false
	/// The target app was told it is active without taking the front.
	public internal(set) var backgroundActivation = false
	/// Result of activating the app, when it had to be activated.
	public internal(set) var activated: Bool?
	/// Result of raising the window, when it had to be raised.
	public internal(set) var raised: Bool?
	/// The element took keyboard focus before input.
	public internal(set) var focused = false
	/// Cmd-A selected the element's text through Accessibility first.
	public internal(set) var selectedAllViaAX = false
	/// bcu opened the menus above the pressed item.
	public internal(set) var openedMenus = false
	/// Background pointer input without evidence; the caller must verify the effect.
	public internal(set) var callerMustVerify = false
	public internal(set) var deltaSource: DeltaSource?

	init(delivery: Delivery) {
		self.delivery = delivery
	}
}

public enum EvidenceSource: String {
	case ax, focus, root, screen
}

/// Why an outcome was judged as it was.
public struct ActEvidence {
	public let source: EvidenceSource
	/// The fact that moved: an AX field (`value`, `selected`, …), `scroll`, `focused` or `changed`.
	public let field: String?
	public let from: String?
	public let to: String?

	init(source: EvidenceSource, field: String? = nil, from: String? = nil, to: String? = nil) {
		self.source = source
		self.field = field
		self.from = from
		self.to = to
	}
}

public enum RootChangeKind: String {
	case appeared, closed, focused
}

public enum RootChange {
	case root(RootChangeKind, Root)
	/// Another app took the front.
	case frontApp(title: String, pid: Int32)
}

public struct ActResult {
	public internal(set) var outcome: ActOutcome
	public internal(set) var performed: ActPerformed
	public internal(set) var verification: ActEvidence?
	public internal(set) var rootDelta: [RootChange] = []

	init(outcome: ActOutcome, performed: ActPerformed, verification: ActEvidence? = nil) {
		self.outcome = outcome
		self.performed = performed
		self.verification = verification
	}
}

public enum ActStep {
	case completed(ActResult)
	case failed(PlatformError)

	public var outcome: ActOutcome {
		if case .completed(let result) = self { return result.outcome }
		return .didnt
	}
}

public struct ActBatchResult {
	public internal(set) var outcome: ActOutcome
	public let steps: [ActStep]
	/// Index of the step that stopped the batch.
	public let stoppedAt: Int?
	public internal(set) var deltaSource: DeltaSource
	public internal(set) var verification: ActEvidence?
	public internal(set) var rootDelta: [RootChange] = []
}

// MARK: Queries

public struct WaitForRequest {
	public let target: RootTarget
	public let role: String?
	public let text: String?
	public let value: String?
	/// Wait for the match to disappear instead of appear.
	public let gone: Bool
	public let scopeRef: String?
	/// Match only the scope element itself.
	public let scopeExact: Bool
	public let timeoutMs: Int?

	public init(target: RootTarget, role: String? = nil, text: String? = nil, value: String? = nil, gone: Bool = false, scopeRef: String? = nil, scopeExact: Bool = false, timeoutMs: Int? = nil) {
		self.target = target
		self.role = role
		self.text = text
		self.value = value
		self.gone = gone
		self.scopeRef = scopeRef
		self.scopeExact = scopeExact
		self.timeoutMs = timeoutMs
	}
}

public enum ElementSource: String {
	case webContent = "web_content_ax"
	case browserChrome = "browser_chrome_ax"
	case desktop = "desktop_ax"
}

/// An element found by a wait, described the way the wire always has.
public struct ElementMatch {
	public let elementRef: String
	public let role: String
	public let subrole: String
	public let title: String
	public let description: String
	public let identifier: String
	public let value: String
	public let actions: [String]
	public let isTextInput: Bool
	public let canSetValue: Bool
	public let canFocus: Bool
	public let canPress: Bool
	public let canScroll: Bool
	public let canIncrement: Bool
	public let canDecrement: Bool
	/// Screen points; the centre is (0, 0) when the element reports no frame.
	public let frame: CGRect?
	public let parentFrame: CGRect?
	public let source: ElementSource
}

public enum WaitForResult {
	case found(ElementMatch, nodeCount: Int)
	case gone(nodeCount: Int)
	case timedOut(nodeCount: Int)
	case rootNotFound
}

public struct ReadTextRequest {
	public let elementRef: String
	public let offset: Int
	public let limit: Int

	public init(elementRef: String, offset: Int = 0, limit: Int = 4_000) {
		self.elementRef = elementRef
		self.offset = offset
		self.limit = limit
	}
}

public struct ReadTextResult {
	public let text: String
	public let offset: Int
	public let limit: Int
	public let totalChars: Int
	public let hasMore: Bool
}
