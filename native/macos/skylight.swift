import AppKit
import CoreGraphics
import Darwin

/// Background input through private SkyLight entry points, ported from trycua/cua (MIT).
///
/// The public `CGEvent.postToPid` skips WindowServer's activity-monitor tickle, so
/// Chromium does not treat those events as live input. `SLEventPostToPid` takes the
/// same route a real device does, and on macOS 14+ keyboard events additionally need an
/// `SLSEventAuthenticationMessage` before Chromium accepts them.
enum SkyLight {
	private typealias PostToPid = @convention(c) (pid_t, CGEvent) -> Void
	private typealias SetIntegerField = @convention(c) (CGEvent, UInt32, Int64) -> Void
	private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
	private typealias SetAuthenticationMessage = @convention(c) (CGEvent, AnyObject) -> Void
	private typealias AuthenticationFactory = @convention(c) (AnyClass, Selector, UnsafeMutableRawPointer, Int32, UInt32) -> Unmanaged<AnyObject>?
	private typealias MainConnection = @convention(c) () -> UInt32
	private typealias WindowOwner = @convention(c) (UInt32, UInt32, UnsafeMutablePointer<UInt32>) -> Int32
	private typealias ConnectionPSN = @convention(c) (UInt32, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
	private typealias PostEventRecord = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> Int32

	private struct Symbols {
		let postToPid: PostToPid
		let setIntegerField: SetIntegerField
		let setWindowLocation: SetWindowLocation
		let setAuthenticationMessage: SetAuthenticationMessage
		let messageSend: AuthenticationFactory
		let mainConnection: MainConnection
		let windowOwner: WindowOwner
		let connectionPSN: ConnectionPSN
		let postEventRecord: PostEventRecord
	}

	private static let symbols: Symbols? = {
		_ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL)
		func resolve<T>(_ name: String, as _: T.Type) -> T? {
			guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
			return unsafeBitCast(pointer, to: T.self)
		}
		guard let postToPid = resolve("SLEventPostToPid", as: PostToPid.self),
			let setIntegerField = resolve("SLEventSetIntegerValueField", as: SetIntegerField.self),
			let setWindowLocation = resolve("CGEventSetWindowLocation", as: SetWindowLocation.self),
			let setAuthenticationMessage = resolve("SLEventSetAuthenticationMessage", as: SetAuthenticationMessage.self),
			let messageSend = resolve("objc_msgSend", as: AuthenticationFactory.self),
			let mainConnection = resolve("CGSMainConnectionID", as: MainConnection.self),
			let windowOwner = resolve("SLSGetWindowOwner", as: WindowOwner.self),
			let connectionPSN = resolve("SLSGetConnectionPSN", as: ConnectionPSN.self),
			let postEventRecord = resolve("SLPSPostEventRecordTo", as: PostEventRecord.self)
		else { return nil }
		return Symbols(postToPid: postToPid, setIntegerField: setIntegerField, setWindowLocation: setWindowLocation, setAuthenticationMessage: setAuthenticationMessage, messageSend: messageSend, mainConnection: mainConnection, windowOwner: windowOwner, connectionPSN: connectionPSN, postEventRecord: postEventRecord)
	}()

	private static func require() throws -> Symbols {
		guard let symbols else {
			throw BridgeFailure(message: "Background input is unavailable: SkyLight entry points did not resolve on this macOS", code: "foreground_required")
		}
		return symbols
	}

	/// Raw SkyLight mouse fields Chromium reads to route and trust a pid-posted gesture.
	private enum Field {
		static let phase: UInt32 = 0
		static let clickState: UInt32 = 1
		static let buttonNumber: UInt32 = 3
		static let subtype: UInt32 = 7
		static let targetPid: UInt32 = 40
		static let windowNumber: UInt32 = 51
		static let clickGroup: UInt32 = 58
		static let windowUnderPointer: UInt32 = 91
		static let windowThatCanHandle: UInt32 = 92
	}
	private static let touchSubtype: Int64 = 3
	/// Where the activation primer lands: outside every window, so it hits no DOM element.
	private static let offscreen = CGPoint(x: -1, y: -1)

	static func post(_ event: CGEvent, to pid: pid_t) throws {
		let symbols = try require()
		if [.keyDown, .keyUp, .flagsChanged].contains(event.type), !event.flags.contains(.maskCommand) {
			authenticate(event, pid: pid, symbols: symbols)
		}
		symbols.postToPid(pid, event)
	}

	/// Menu key equivalents only fire through the unauthenticated route, which is why
	/// command chords skip the envelope. `messageWithEventRecord:pid:version:` exists from
	/// macOS 15; without it the event still posts, unauthenticated.
	private static func authenticate(_ event: CGEvent, pid: pid_t, symbols: Symbols) {
		let selector = NSSelectorFromString("messageWithEventRecord:pid:version:")
		guard let factory = NSClassFromString("SLSEventAuthenticationMessage"),
			class_respondsToSelector(object_getClass(factory), selector),
			let record = eventRecord(event),
			let message = symbols.messageSend(factory, selector, record, pid, 0)?.takeUnretainedValue()
		else { return }
		symbols.setAuthenticationMessage(event, message)
	}

	/// `__CGEvent` is `{CFRuntimeBase, uint32_t, SLSEventRecord *}`; the record pointer
	/// moved between releases, so the known offsets are probed in order.
	private static func eventRecord(_ event: CGEvent) -> UnsafeMutableRawPointer? {
		let base = Unmanaged.passUnretained(event).toOpaque()
		for offset in [24, 32, 16] {
			if let record = base.load(fromByteOffset: offset, as: UnsafeMutableRawPointer?.self) { return record }
		}
		return nil
	}

	/// Where a pointer event goes: WindowServer routes it to `windowId` of `pid` even when that
	/// window is neither frontmost nor under the real pointer.
	struct PointerRoute {
		let pid: pid_t
		let windowId: UInt32
		/// Top-left of the window in screen points; the window location is relative to it.
		let windowOrigin: CGPoint
	}

	private static func post(_ event: CGEvent, along route: PointerRoute, at location: CGPoint, fields: [(UInt32, Int64)], symbols: Symbols) {
		let routing: [(UInt32, Int64)] = [
			(Field.targetPid, Int64(route.pid)), (Field.windowNumber, Int64(route.windowId)),
			(Field.windowUnderPointer, Int64(route.windowId)), (Field.windowThatCanHandle, Int64(route.windowId)),
		]
		for (field, value) in routing + fields { symbols.setIntegerField(event, field, value) }
		symbols.setWindowLocation(event, location == offscreen ? offscreen : CGPoint(x: location.x - route.windowOrigin.x, y: location.y - route.windowOrigin.y))
		symbols.postToPid(route.pid, event)
	}

	/// One Chromium-trusted click: a move to the target, a primer press outside every
	/// window that satisfies the user-activation gate without touching the page, then the
	/// real presses.
	static func click(at point: CGPoint, along route: PointerRoute, button: CGMouseButton, clickCount: Int) throws {
		let symbols = try require()
		let group = Int64(DispatchTime.now().uptimeNanoseconds & 0x7fff_ffff)
		let (down, up) = mouseTypes(button)
		func send(_ type: CGEventType, at location: CGPoint, phase: Int64, clickState: Int64) throws {
			guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else {
				throw BridgeFailure(message: "Failed to create mouse event", code: "input_failed")
			}
			post(event, along: route, at: location, fields: [
				(Field.phase, phase), (Field.clickState, clickState), (Field.buttonNumber, Int64(button.rawValue)),
				(Field.subtype, touchSubtype), (Field.clickGroup, group),
			], symbols: symbols)
		}
		try send(.mouseMoved, at: point, phase: 2, clickState: 0)
		usleep(15_000)
		try send(down, at: offscreen, phase: 1, clickState: 1)
		usleep(1_000)
		try send(up, at: offscreen, phase: 2, clickState: 1)
		usleep(100_000)
		for index in 1...max(1, clickCount) {
			try send(down, at: point, phase: 3, clickState: Int64(index))
			usleep(1_000)
			try send(up, at: point, phase: 3, clickState: Int64(index))
			if index < clickCount { usleep(80_000) }
		}
	}

	/// A wheel turn at `point`: the renderer scrolls whatever is scrollable under it, so a
	/// move first primes the window's idea of where the pointer is.
	static func scroll(at point: CGPoint, along route: PointerRoute, deltaX: Int, deltaY: Int) throws {
		let symbols = try require()
		guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
			let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-deltaY), wheel2: Int32(deltaX), wheel3: 0)
		else { throw BridgeFailure(message: "Failed to create scroll event", code: "input_failed") }
		wheel.location = point
		post(move, along: route, at: point, fields: [], symbols: symbols)
		usleep(15_000)
		post(wheel, along: route, at: point, fields: [], symbols: symbols)
	}

	private static func mouseTypes(_ button: CGMouseButton) -> (CGEventType, CGEventType) {
		switch button {
		case .right: return (.rightMouseDown, .rightMouseUp)
		case .center: return (.otherMouseDown, .otherMouseUp)
		default: return (.leftMouseDown, .leftMouseUp)
		}
	}

	/// Posts one 248-byte Carbon event record to the process that owns `windowId`: size at
	/// 0x04, kind at 0x08, window at 0x3c. yabai's focus-without-raise is built from these.
	private static func postRecord(owning windowId: UInt32, about window: UInt32, kind: UInt8, symbols: Symbols, _ fill: (inout [UInt8]) -> Void) throws {
		var owner: UInt32 = 0
		var psn = ProcessSerialNumber()
		guard symbols.windowOwner(symbols.mainConnection(), windowId, &owner) == 0,
			symbols.connectionPSN(owner, &psn) == 0
		else { throw BridgeFailure(message: "Could not resolve the process of window \(windowId)", code: "foreground_required") }
		var record = [UInt8](repeating: 0, count: 0xF8)
		record[0x04] = 0xF8
		record[0x08] = kind
		withUnsafeBytes(of: window.littleEndian) { record.replaceSubrange(0x3C..<0x40, with: $0) }
		fill(&record)
		guard symbols.postEventRecord(&psn, record) == 0 else {
			throw BridgeFailure(message: "WindowServer refused to focus window \(windowId)", code: "foreground_required")
		}
	}

	/// Tells the process that owns `windowId` it is active, without changing WindowServer's
	/// front process or reordering windows, so a view that rejects the first mouse event of
	/// an inactive app still takes a background click. yabai and cua also defocus the current
	/// front process first; measured, that makes the user's front app resign its key window
	/// and its activation, and the keystrokes the user types next are lost. So only the
	/// target is told.
	static func activateWithoutRaise(windowId: UInt32) throws {
		try postRecord(owning: windowId, about: windowId, kind: 0x0D, symbols: try require()) { $0[0x8A] = 0x01 }
	}

	/// Makes `windowId` the key window of its own process without activating the process
	/// or reordering any window: keyboard input posted to a pid goes to its key window.
	/// This is yabai's focus-without-raise recipe minus its front-process switch: move the
	/// process's focus from `currentKey` to the window, then send the make-key pair.
	static func makeKeyWithoutRaise(windowId: UInt32, currentKey: UInt32?) throws {
		let symbols = try require()
		if let currentKey {
			try postRecord(owning: windowId, about: currentKey, kind: 0x0D, symbols: symbols) { $0[0x8A] = 0x02 }
			// Some apps drop the focus half when both arrive in the same instant.
			usleep(10_000)
			try postRecord(owning: windowId, about: windowId, kind: 0x0D, symbols: symbols) { $0[0x8A] = 0x01 }
		}
		for kind: UInt8 in [0x01, 0x02] {
			try postRecord(owning: windowId, about: windowId, kind: kind, symbols: symbols) { record in
				record[0x3A] = 0x10
				record.replaceSubrange(0x20..<0x30, with: repeatElement(0xFF, count: 0x10))
			}
		}
	}
}
