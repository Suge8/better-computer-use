import AppKit
import BCUCore

extension Platform {
	/// Input posted to a pid lands in its key window. Returns whether a handoff was needed;
	/// throws when the window did not become key, because the input would land elsewhere.
	func focusWindowWithoutRaise(pid: Int32, windowId: UInt32) throws -> Bool {
		guard windowId != 0, let window = resolveRoot(pid: pid, windowId: windowId) else { return false }
		let app = AXUIElementCreateApplication(pid)
		func keyWindow() -> AXUIElement? { copyAttribute(app, attribute: kAXFocusedWindowAttribute as CFString).flatMap(asAXElement) }
		func isKey() -> Bool { keyWindow().map { sameElement($0, window) } ?? false }
		let current = keyWindow()
		if isKey() { return false }
		try SkyLight.makeKeyWithoutRaise(windowId: windowId, currentKey: current.flatMap { pairingForWindow($0, pid: pid).candidate?.windowId })
		guard try awaitChange(in: pid, timeout: Self.activationTimeout, isKey) else {
			throw ForegroundRequired(message: "Window \(windowId) did not become the key window of its app")
		}
		return true
	}

	func postEvent(_ event: CGEvent, pid: Int32, delivery: Delivery = .hid) throws {
		if delivery == .pid {
			try SkyLight.post(event, to: pid)
			return
		}
		// Post as a real foreground HID event. AppKit views with mouseDown handlers
		// can ignore pid-targeted CGEvents, so keep the target app frontmost and post
		// at the session event tap.
		if let app = NSRunningApplication(processIdentifier: pid), !app.isActive {
			_ = app.activate()
			_ = try awaitChange(in: pid, timeout: Self.activationTimeout) { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
		}
		event.post(tap: .cghidEventTap)
	}

	func postMouseMove(to point: CGPoint, pid: Int32, delivery: Delivery = .hid) throws {
		if delivery == .hid { physicalInputLock.lock() }
		defer { if delivery == .hid { physicalInputLock.unlock() } }
		guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
			throw BCUError(.actionFailed, "Failed to create mouse move event")
		}
		try postEvent(move, pid: pid, delivery: delivery)
	}

	func mouseDownType(for button: CGMouseButton) -> CGEventType {
		switch button {
		case .right:
			return .rightMouseDown
		case .center:
			return .otherMouseDown
		default:
			return .leftMouseDown
		}
	}

	func mouseUpType(for button: CGMouseButton) -> CGEventType {
		switch button {
		case .right:
			return .rightMouseUp
		case .center:
			return .otherMouseUp
		default:
			return .leftMouseUp
		}
	}

	func mouseDraggedType(for button: CGMouseButton) -> CGEventType {
		switch button {
		case .right:
			return .rightMouseDragged
		case .center:
			return .otherMouseDragged
		default:
			return .leftMouseDragged
		}
	}

	func postMouseClick(at point: CGPoint, pid: Int32, route: SkyLight.PointerRoute, button: CGMouseButton = .left, clickCount: Int = 1, delivery: Delivery = .hid) throws {
		if delivery == .pid {
			try SkyLight.click(at: point, along: route, button: button, clickCount: clickCount)
			return
		}
		physicalInputLock.lock()
		defer { physicalInputLock.unlock() }
		try postMouseMove(to: point, pid: pid, delivery: delivery)
		for index in 1...max(1, clickCount) {
			guard let down = CGEvent(mouseEventSource: nil, mouseType: mouseDownType(for: button), mouseCursorPosition: point, mouseButton: button),
				let up = CGEvent(mouseEventSource: nil, mouseType: mouseUpType(for: button), mouseCursorPosition: point, mouseButton: button)
			else {
				throw BCUError(.actionFailed, "Failed to create mouse click event")
			}
			down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
			up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
			try postEvent(down, pid: pid, delivery: delivery)
			usleep(12_000)
			try postEvent(up, pid: pid, delivery: delivery)
			if index < clickCount {
				usleep(70_000)
			}
		}
	}

	func postMouseDrag(points: [CGPoint], pid: Int32, route: SkyLight.PointerRoute, delivery: Delivery = .hid) throws {
		guard points.count >= 2, let first = points.first else {
			throw BCUError(.invalidArguments, "Drag requires at least two points")
		}
		if delivery == .pid {
			try SkyLight.drag(points, along: route)
			return
		}
		physicalInputLock.lock()
		defer { physicalInputLock.unlock() }
		try postMouseMove(to: first, pid: pid, delivery: delivery)
		guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: first, mouseButton: .left) else {
			throw BCUError(.actionFailed, "Failed to create mouse down event")
		}
		try postEvent(down, pid: pid, delivery: delivery)
		usleep(12_000)

		for point in points.dropFirst() {
			guard let drag = CGEvent(mouseEventSource: nil, mouseType: mouseDraggedType(for: .left), mouseCursorPosition: point, mouseButton: .left) else {
				throw BCUError(.actionFailed, "Failed to create mouse drag event")
			}
			try postEvent(drag, pid: pid, delivery: delivery)
			usleep(8_000)
		}

		guard let last = points.last,
			let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: last, mouseButton: .left)
		else {
			throw BCUError(.actionFailed, "Failed to create mouse up event")
		}
		try postEvent(up, pid: pid, delivery: delivery)
	}

	func postScrollWheel(at point: CGPoint, deltaX: Int, deltaY: Int, pid: Int32, route: SkyLight.PointerRoute, delivery: Delivery = .hid) throws {
		let notches = try wheelNotches(at: point, deltaX: deltaX, deltaY: deltaY)
		if delivery == .pid {
			try SkyLight.scroll(notches, at: point, along: route)
			return
		}
		physicalInputLock.lock()
		defer { physicalInputLock.unlock() }
		try postMouseMove(to: point, pid: pid, delivery: delivery)
		for notch in notches {
			try postEvent(notch, pid: pid, delivery: delivery)
			usleep(wheelNotchInterval)
		}
	}
}

/// Pause between two wheel notches, about how fast a physical wheel reports them.
let wheelNotchInterval: useconds_t = 15_000

/// `deltaX` and `deltaY` notches at `point`, one line-based wheel event each, the way a
/// physical mouse wheel reports them. Qt counts every such event as one notch whatever its
/// size and a few pixels of precise delta as a fraction of one, so a pixel delta of 5 scrolls
/// a Qt list not at all; AppKit and Chromium scroll a line per notch. Positive y scrolls the
/// content toward its end, positive x toward its right.
func wheelNotches(at point: CGPoint, deltaX: Int, deltaY: Int) throws -> [CGEvent] {
	try (0..<max(abs(deltaX), abs(deltaY))).map { index in
		let y = index < abs(deltaY) ? -deltaY.signum() : 0
		let x = index < abs(deltaX) ? -deltaX.signum() : 0
		guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(y), wheel2: Int32(x), wheel3: 0) else {
			throw BCUError(.actionFailed, "Failed to create scroll event")
		}
		event.location = point
		return event
	}
}
