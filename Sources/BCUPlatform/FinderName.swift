import AppKit

extension Platform {
	static let finderBundleId = "com.apple.finder"

	/// Finder shows a file's name in text fields whose AXValue accepts a write and reads it
	/// back, but only the display changes: the file keeps its name. These are the name cell of
	/// a list view (it carries AXFilename and a file AXURL, and is not being edited) and the
	/// Name & Extension field of a Get Info window. Returns the keyboard route that does
	/// rename the file, nil for any other field.
	func finderRenameRoute(for element: AXUIElement, pid: Int32) -> String? {
		let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString)
		guard role == kAXTextFieldRole as String else { return nil }
		let steps = "observe the window with --image always, then act-ui --foreground with: "
		let edit = "keypress cmd+a, typeText the new name, keypress Return"
		let isListName = stringAttribute(element, attribute: "AXFilename" as CFString) != nil
			&& (copyAttribute(element, attribute: kAXURLAttribute as CFString) as? URL)?.isFileURL == true
			&& boolAttribute(element, attribute: kAXFocusedAttribute as CFString) != true
		if isListName {
			return "Rename it from the keyboard: \(steps)click the name, keypress Return, wait 400 ms, \(edit)."
		}
		let isInfoName = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == Self.finderBundleId
			&& stringAttribute(element, attribute: kAXIdentifierAttribute as CFString) == "Name"
		return isInfoName ? "Rename it from the keyboard: \(steps)click the field, \(edit)." : nil
	}

	/// Errors of AXPerformAction that prove the request never reached the app. Others (a
	/// timeout while the app is busy with the press, a generic failure Finder's own toolbar
	/// returns for presses that landed) say nothing about whether it ran.
	static func pressNeverArrived(_ status: AXError) -> Bool {
		[.invalidUIElement, .illegalArgument, .notImplemented].contains(status)
	}
}
