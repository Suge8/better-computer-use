import AppKit

/// What asking an app for its full accessibility tree found out, kept for the process's lifetime.
struct AccessibilityRequest: Sendable {
	/// The app builds web content: a browser, or an app that took AXManualAccessibility (Chromium, Electron).
	var buildsWebContent: Bool
	/// When the app last failed to answer the request; it is asked again once the backoff has passed.
	var failedAt: Date?
	/// When a window's web content last failed to appear in time; it is not waited for again
	/// before the backoff has passed.
	var timedOutAt: Date?
}

/// Chromium and Electron build their web-content accessibility tree only once an assistive
/// client asks for it, and build it asynchronously, a second or more later. Ported from
/// trycua/cua (4f7084573, 1e93424e5): ask with AXManualAccessibility, with the legacy
/// AXEnhancedUserInterface only where that one is unsupported; wait for the window's web area
/// to have children instead of sleeping a fixed time; and never keep a failure for good.
extension Platform {
	/// How long a browser window's web content may take to appear.
	static let webContentTimeout: TimeInterval = 4
	/// Chromium posts its notifications while it builds the tree and fills the web area a
	/// moment after the last one, so between notifications the window is looked at again this often.
	static let webContentRecheck: TimeInterval = 0.1
	/// A process whose web content timed out, or that did not answer the request, is not
	/// waited for or asked again before this.
	static let webContentBackoff: TimeInterval = 30
	/// How deep and how wide the look for a web area goes.
	static let webAreaDepth = 10
	static let webAreaVisits = 400

	/// Asks the app for its full accessibility tree, once per process lifetime; nil only when
	/// the process is gone. An app too busy to answer is asked again after the backoff; a
	/// browser counts as building web content whether or not it answered, so its windows are
	/// still waited for and reported.
	@discardableResult
	func requestAccessibility(pid: Int32) -> AccessibilityRequest? {
		guard let process = ProcessIdentity(pid: pid) else { return nil }
		let known = accessibilityRequests.withLock { $0[process] }
		if let known, known.failedAt.map({ Date().timeIntervalSince($0) < Self.webContentBackoff }) ?? true { return known }
		let manual = assertAccessibility(pid: pid)
		let request = AccessibilityRequest(
			buildsWebContent: manual == true || known?.buildsWebContent == true || isBrowser(pid: pid),
			failedAt: manual == nil ? Date() : nil,
			timedOutAt: known?.timedOutAt
		)
		accessibilityRequests.withLock { $0[process] = request }
		return request
	}

	/// True when the app took AXManualAccessibility, false when it does not support it, nil
	/// when it could not answer. Chromium builds its tree on AXEnhancedUserInterface even
	/// while answering that it does not implement it (measured: Chrome for Testing 153), so that
	/// answer is not read.
	private func assertAccessibility(pid: Int32) -> Bool? {
		let app = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(app, quickMessagingTimeout)
		let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
		if manual == .success { return true }
		guard manual == .attributeUnsupported else { return nil }
		_ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
		return false
	}

	/// Whether a standard window of an app that builds web content still lacks it; such a
	/// window always holds a web area once its page is exposed.
	func lacksWebContent(_ outline: LookNode, window: AXUIElement, request: AccessibilityRequest?) -> Bool {
		guard request?.buildsWebContent == true,
			stringAttribute(window, attribute: kAXSubroleAttribute as CFString) == kAXStandardWindowSubrole as String
		else { return false }
		return !hasWebContent(outline)
	}

	/// Waits until the window's web area has children; whether it does. Notifications of the
	/// app end each wait at once; a process whose content timed out within the backoff is not
	/// waited for, and the timeout is recorded with the process, never for good.
	func awaitWebContent(pid: Int32, window: AXUIElement) -> Bool {
		guard let process = ProcessIdentity(pid: pid) else { return false }
		if let last = accessibilityRequests.withLock({ $0[process]?.timedOutAt }), Date().timeIntervalSince(last) < Self.webContentBackoff {
			return false
		}
		let notifications = try? observedApp(pid)
		let start = Date()
		let deadline = start.addingTimeInterval(Self.webContentTimeout)
		var reasserted = false
		while true {
			let generation = notifications?.generation
			if webAreaPopulated(in: window) {
				accessibilityRequests.withLock { $0[process]?.timedOutAt = nil }
				return true
			}
			let now = Date()
			if now >= deadline { break }
			// Asked once more halfway, as cua does: a request made while the app was busy can be lost.
			if !reasserted, now.timeIntervalSince(start) >= Self.webContentTimeout / 2 {
				_ = assertAccessibility(pid: pid)
				reasserted = true
			}
			let next = min(deadline, now.addingTimeInterval(Self.webContentRecheck))
			if let notifications, let generation { notifications.wait(since: generation, until: next) } else { Thread.sleep(until: next) }
		}
		accessibilityRequests.withLock { $0[process]?.timedOutAt = Date() }
		return false
	}

	/// A web area with children among the look's nodes; one cut short counts, its children were not walked.
	private func hasWebContent(_ node: LookNode) -> Bool {
		if node.role == "AXWebArea" { return !node.children.isEmpty || node.truncated }
		return node.children.contains(where: hasWebContent)
	}

	/// The live window holds a web area with children; the menu bar never does.
	private func webAreaPopulated(in window: AXUIElement) -> Bool {
		var visits = Self.webAreaVisits
		func search(_ element: AXUIElement, depth: Int) -> Bool {
			guard depth > 0 else { return false }
			for child in axElementArray(element, attribute: kAXChildrenAttribute as CFString) {
				guard visits > 0 else { return false }
				visits -= 1
				switch stringAttribute(child, attribute: kAXRoleAttribute as CFString) {
				case kAXMenuBarRole as String: continue
				case "AXWebArea": if !axElementArray(child, attribute: kAXChildrenAttribute as CFString).isEmpty { return true }
				default: if search(child, depth: depth - 1) { return true }
				}
			}
			return false
		}
		return search(window, depth: Self.webAreaDepth)
	}
}
