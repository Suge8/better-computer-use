import AppKit
import BCUCore

// Request and result types of the Platform API. Elements and roots travel as `Handle`s the
// caller keeps with its observation; failures are thrown as `BCUError` with their public code.

/// The action needs the real pointer or the frontmost app, which the requested policy does
/// not allow; the caller may retry it in the foreground.
public struct ForegroundRequired: Error, Sendable {
	public let message: String
}

// MARK: Diagnostics and permissions

public struct Diagnostics: Sendable {
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
public enum PermissionAttribution: String, Sendable {
	/// The installed bundle launched through LaunchServices: grants belong to bcu.app.
	case bcuApp = "bcu-app"
	/// Anything else: the booleans reflect whatever app spawned this process.
	case caller
}

public struct PermissionSource: Sendable {
	public let pid: Int32
	public let parentPid: Int32
	public let parentPath: String?
	public let parentBundleId: String?
	public let executablePath: String
	public let macOS: String
	public let attribution: PermissionAttribution
}

public struct PermissionStatus: Sendable {
	public let accessibility: Bool
	/// The system's answer as this process first cached it; see `Platform.checkPermissions`.
	public let screenRecording: Bool
	public let source: PermissionSource
}

public struct PermissionRegistration: Sendable {
	public let accessibility: Bool
	public let screenRecording: Bool
}

// MARK: Apps and roots

public struct RunningApp: Sendable {
	public let appName: String
	public let pid: Int32
	public let bundleId: String?
	public let isFrontmost: Bool
}

public enum PairingConfidence: String, Sendable {
	case exact, high, low
}

/// How surely an accessibility root was matched to a window-server window.
public struct RootPairing: Sendable {
	public let confidence: PairingConfidence
	public let score: Double
}

public struct RootMetadata: Sendable {
	public let pairing: RootPairing
	public let sheetCount: Int
}

public struct Root: Sendable {
	public let kind: RootKind
	/// The root's identity: equal handles name the same root, whatever its title or frame.
	public let handle: Handle
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

public struct Frontmost: Sendable {
	public let appName: String
	public let pid: Int32
	public let bundleId: String?
	/// The app's most prominent window, when it has one.
	public let window: Root?
}

// MARK: Look

/// Where a look's outline coordinates come from: its image when it has one, else the
/// root's frame in points. Actions at coordinates of that look are placed through it.
public struct LookGeometry: Sendable {
	public let windowId: UInt32
	public let windowFrame: CGRect
	public let imageWidth: Int
	public let imageHeight: Int
	public let hasImage: Bool
}

public struct LookRequest: Sendable {
	public let root: Handle
	public let windowId: UInt32?
	public let maxDimension: Int?
	public let readText: ReadTextMode
	/// The geometry of the look this one refines; a scoped look keeps it so coordinates stay valid.
	public let baseGeometry: LookGeometry?
	public let includeImage: Bool
	/// An element of the root to describe instead of the whole root.
	public let scope: Handle?

	public init(root: Handle, windowId: UInt32? = nil, maxDimension: Int? = nil, readText: ReadTextMode = .auto, baseGeometry: LookGeometry? = nil, includeImage: Bool = true, scope: Handle? = nil) {
		self.root = root
		self.windowId = windowId
		self.maxDimension = maxDimension
		self.readText = readText
		self.baseGeometry = baseGeometry
		self.includeImage = includeImage
		self.scope = scope
	}
}

public struct LookWindow: Sendable {
	public let windowId: UInt32
	public let kind: RootKind
	public let framePoints: CGRect
	public let scaleFactor: Double
	public let isModal: Bool
	public let metadata: RootMetadata
	public let role: String
	public let subrole: String
}

public struct LookTimings: Sendable {
	public let captureMs: Int
	public let describeMs: Int
	public let readTextMs: Int
}

public struct LookImage: Sendable {
	public let jpeg: Data
	public let width: Int
	public let height: Int
}

public struct LookResult {
	public let capturedAt: Date
	public let window: LookWindow
	public let outline: LookNode
	public let geometry: LookGeometry
	public let timings: LookTimings
	/// Whether the screen was read; nil for a picture-only popup menu.
	public let readText: (requested: ReadTextMode, executed: Bool)?
	public let image: LookImage?
}

// MARK: Act

public enum ActAction: String, Sendable {
	case press, click, moveMouse, scroll, drag, setText, typeText, keypress
}

public enum ActTarget: Sendable {
	/// An element handle from the look.
	case element(Handle)
	/// A point in the look's image coordinates.
	case point(x: Double, y: Double)
}

/// The rung of the delivery ladder a call may start from; see docs/architecture.md.
public enum ActPolicy: String, Sendable {
	case `default`, background, foreground
	case axOnly = "ax_only"
}

public struct ActionInput: Sendable {
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

public struct ActRequest: Sendable {
	/// The look the target was taken from.
	public let geometry: LookGeometry
	public let pid: Int32
	public let action: ActAction
	public let target: ActTarget
	public let params: ActionInput
	public let policy: ActPolicy
	/// Animate the agent cursor over pointer actions delivered in the background.
	public let cursorOverlay: Bool

	public init(geometry: LookGeometry, pid: Int32, action: ActAction, target: ActTarget, params: ActionInput = ActionInput(), policy: ActPolicy = .default, cursorOverlay: Bool = true) {
		self.geometry = geometry
		self.pid = pid
		self.action = action
		self.target = target
		self.params = params
		self.policy = policy
		self.cursorOverlay = cursorOverlay
	}
}

public enum Delivery: String, Sendable {
	case ax, pid, hid
}

public enum Grounding: String, Sendable {
	case description, coordinates
}

/// Where the root change of an action was first noticed.
public enum DeltaSource: String, Sendable {
	/// Nothing announced a change; the roots were diffed at the timeout.
	case snapshot
	/// A notification of the app said a root opened, closed or took focus.
	case events
	/// The window server's list of the app's windows, or the front app, changed.
	case windowList = "window-list"
}

/// What the platform did to deliver an action, beyond the action itself.
public struct ActPerformed: Sendable {
	public internal(set) var delivery: Delivery
	public internal(set) var grounding: Grounding?
	/// The element's accessibility object was replaced and it was found again.
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

public enum RootChangeKind: String, Sendable {
	case appeared, closed, focused
}

public enum RootChange: Sendable {
	case root(RootChangeKind, Root)
	/// Another app took the front.
	case frontApp(title: String, pid: Int32)
}

public struct ActionReport: Sendable {
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

public enum ActStep: Sendable {
	case completed(ActionReport)
	/// The step could not be delivered; nothing after it was tried.
	case failed(BCUError)

	public var outcome: ActOutcome {
		if case .completed(let result) = self { return result.outcome }
		return .didnt
	}
}

public struct BatchReport: Sendable {
	public internal(set) var outcome: ActOutcome
	public let steps: [ActStep]
	/// Index of the step that stopped the batch.
	public let stoppedAt: Int?
	public internal(set) var deltaSource: DeltaSource
	public internal(set) var verification: ActEvidence?
	public internal(set) var rootDelta: [RootChange] = []
}

// MARK: Queries

public struct WaitForRequest: Sendable {
	public let pid: Int32
	public let root: Handle
	public let role: String?
	public let text: String?
	public let value: String?
	/// Wait for the match to disappear instead of appear.
	public let gone: Bool
	public let scope: Handle?
	public let timeoutMs: Int?

	public init(pid: Int32, root: Handle, role: String? = nil, text: String? = nil, value: String? = nil, gone: Bool = false, scope: Handle? = nil, timeoutMs: Int? = nil) {
		self.pid = pid
		self.root = root
		self.role = role
		self.text = text
		self.value = value
		self.gone = gone
		self.scope = scope
		self.timeoutMs = timeoutMs
	}
}

public struct ChangeMark: Sendable {
	let generation: UInt64
}

public enum WaitOutcome: Sendable {
	case found
	case gone
	case timedOut
	case rootNotFound
}

public struct TextPage: Sendable {
	public let text: String
	public let offset: Int
	public let limit: Int
	public let totalChars: Int
	public let hasMore: Bool
}
