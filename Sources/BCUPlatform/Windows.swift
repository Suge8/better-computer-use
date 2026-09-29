import AppKit

// Window and focus control outside the observe → act loop.
extension Platform {
	/// The frontmost app with its focused window and focused element.
	public func userContext() throws -> UserContext {
		guard let app = NSWorkspace.shared.frontmostApplication else {
			throw PlatformError(message: "No frontmost app available", code: "frontmost_unavailable")
		}
		let pid = app.processIdentifier
		ensureEnhancedAccessibility(pid: pid)
		let appElement = AXUIElementCreateApplication(pid)
		let focusedWindow = copyAttribute(appElement, attribute: kAXFocusedWindowAttribute as CFString).flatMap(asAXElement)
		let focusedElement = copyAttribute(appElement, attribute: kAXFocusedUIElementAttribute as CFString).flatMap(asAXElement)
		return UserContext(
			appName: app.localizedName ?? "Unknown App",
			pid: pid,
			bundleId: app.bundleIdentifier,
			window: focusedWindow.map { window in
				UserContext.Window(
					title: stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? "",
					role: stringAttribute(window, attribute: kAXRoleAttribute as CFString) ?? "",
					subrole: stringAttribute(window, attribute: kAXSubroleAttribute as CFString) ?? ""
				)
			},
			focusedElement: focusedElement.map { element in
				let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
				let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
				return UserContext.Element(
					role: role,
					subrole: subrole,
					title: stringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? "",
					description: stringAttribute(element, attribute: kAXDescriptionAttribute as CFString) ?? "",
					value: displayValue(element, role: role, subrole: subrole)
				)
			}
		)
	}

	/// Swallows the user's keyboard and mouse until `endInputSuppression`, or for at most
	/// `InputSuppressionGuard.maxSuppressionSeconds`.
	public func beginInputSuppression() throws {
		try inputSuppressionGuard.begin()
	}

	public func endInputSuppression() {
		inputSuppressionGuard.end()
	}

	/// Brings an app back to the front and, when given, its window with that title.
	public func restoreUserFocus(pid: Int32, windowTitle: String?) throws -> RestoredFocus {
		let targetTitle = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard let app = NSRunningApplication(processIdentifier: pid) else {
			throw PlatformError(message: "App with pid \(pid) is no longer running", code: "app_not_found")
		}

		let appRestored = app.activate()
		var restoredWindowTitle = ""
		var windowRestored = false

		if !targetTitle.isEmpty {
			let appElement = AXUIElementCreateApplication(pid)
			let windows = axElementArray(appElement, attribute: kAXWindowsAttribute as CFString)
			let normalizedTarget = targetTitle.lowercased()
			if let match = windows.first(where: {
				(stringAttribute($0, attribute: kAXTitleAttribute as CFString) ?? "")
					.trimmingCharacters(in: .whitespacesAndNewlines)
					.lowercased() == normalizedTarget
			}) {
				restoredWindowTitle = stringAttribute(match, attribute: kAXTitleAttribute as CFString) ?? ""
				let setMainStatus = AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
				let setFocusedStatus = AXUIElementSetAttributeValue(match, kAXFocusedAttribute as CFString, kCFBooleanTrue)
				let raiseStatus = AXUIElementPerformAction(match, kAXRaiseAction as CFString)
				windowRestored = setMainStatus == .success || setFocusedStatus == .success || raiseStatus == .success
			}
		}

		return RestoredFocus(appRestored: appRestored, windowRestored: windowRestored, appName: app.localizedName ?? "Unknown App", windowTitle: restoredWindowTitle)
	}

	/// Moves and resizes a root; the size is clamped to at least 100×80 points. Nil when the
	/// root is not found.
	public func setWindowFrame(_ target: RootTarget, frame requested: CGRect) throws -> WindowFrameResult? {
		guard let window = resolveRoot(pid: target.pid, windowId: target.windowId, rootRef: target.rootRef) else { return nil }
		var origin = requested.origin
		var size = CGSize(width: max(100.0, requested.width), height: max(80.0, requested.height))
		guard let originValue = AXValueCreate(.cgPoint, &origin), let sizeValue = AXValueCreate(.cgSize, &size) else {
			throw PlatformError(message: "Failed to create AX frame values", code: "frame_value_failed")
		}
		let positionStatus = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
		let sizeStatus = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
		return WindowFrameResult(positionStatus: positionStatus, sizeStatus: sizeStatus, framePoints: frameForWindow(window))
	}

	/// The app's focused element, optionally required to lie inside a root.
	public func focusedElement(_ target: RootTarget) -> FocusedElementResult {
		let app = AXUIElementCreateApplication(target.pid)
		guard let focusedValue = copyAttribute(app, attribute: kAXFocusedUIElementAttribute as CFString),
			let element = asAXElement(focusedValue)
		else {
			return .none
		}
		if target.windowId != nil || target.rootRef != nil {
			guard let window = resolveRoot(pid: target.pid, windowId: target.windowId, rootRef: target.rootRef) else {
				return .rootNotFound
			}
			guard isElement(element, descendantOf: window) else {
				return .outsideRoot
			}
		}

		let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
		let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
		var settable = DarwinBoolean(false)
		let settableStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
		let canSetValue = settableStatus == .success && settable.boolValue
		let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXComboBox", "AXEditableText", "AXSecureTextField"]
		return .element(FocusedElement(
			elementRef: refStore.storeElement(element),
			role: role,
			subrole: subrole,
			isTextInput: textRoles.contains(role) || canSetValue,
			isSecure: role == "AXSecureTextField" || subrole == "AXSecureTextField",
			canSetValue: canSetValue
		))
	}

	/// The pointer in AppKit screen coordinates (origin at the bottom left).
	public func mousePosition() -> CGPoint {
		NSEvent.mouseLocation
	}
}
