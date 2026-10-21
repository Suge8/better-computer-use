import AppKit

/// How long an accessibility request to an app may block: short where one unresponsive app
/// must not stall the others (broad discovery, starting an observer), longer where one app is
/// the target.
let quickMessagingTimeout: Float = 0.25
let messagingTimeout: Float = 1.0
extension Platform {
	func isBrowser(pid: Int32) -> Bool {
		let app = NSRunningApplication(processIdentifier: pid)
		if browserBundleIds.contains(app?.bundleIdentifier ?? "") { return true }
		let name = (app?.localizedName ?? processName(pid: pid) ?? "").lowercased()
		return ["chrome", "chromium", "brave", "edge", "vivaldi", "opera", "firefox", "helium"].contains { name.contains($0) }
	}

	/// Whether an element of the observed tree under `root` (see `collectDescendants`)
	/// `matches`; nil when the deadline stopped the search before it found one or saw them all.
	/// No element is read after the deadline.
	func containsDescendant(startingAt root: AXUIElement, until deadline: Date, where matches: (AXUIElement) -> Bool) -> Bool? {
		var queue = [root]
		var seen = Set<ObjectIdentifier>()
		var index = 0
		while index < queue.count && seen.count < Self.outlineNodeLimit {
			guard Date() < deadline else { return nil }
			let element = queue[index]
			index += 1
			guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
			if matches(element) { return true }
			queue += axElementArray(element, attribute: kAXChildrenAttribute as CFString)
		}
		return false
	}

	/// The root and its descendants, breadth first, each element once. Without a depth, this is
	/// the tree an observation describes: the same walk with the same node limit, so whatever
	/// observe-ui shows a wait, a re-find or a coordinate can reach. Web content sits a dozen
	/// levels deep or more (Chromium's own pages, frames), so no depth short of that is safe.
	func collectDescendants(startingAt root: AXUIElement, maxDepth: Int = .max, maxNodes: Int = outlineNodeLimit) -> [AXUIElement] {
		let nodeLimit = max(1, maxNodes)
		var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
		var seen = Set<ObjectIdentifier>()
		var index = 0
		var output: [AXUIElement] = []
		while index < queue.count && output.count < nodeLimit {
			let (element, depth) = queue[index]
			index += 1
			guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
			output.append(element)
			if depth >= maxDepth { continue }
			for child in axElementArray(element, attribute: kAXChildrenAttribute as CFString) {
				if queue.count >= nodeLimit { break }
				queue.append((child, depth + 1))
			}
		}
		return output
	}

	func frameForElement(_ element: AXUIElement) -> CGRect? {
		let origin = pointAttribute(element, attribute: kAXPositionAttribute as CFString)
		let size = sizeAttribute(element, attribute: kAXSizeAttribute as CFString)
		guard let origin, let size, size.width > 0, size.height > 0 else { return nil }
		return CGRect(origin: origin, size: size)
	}

	func pidForElement(_ element: AXUIElement) -> Int32? {
		var pid: pid_t = 0
		let status = AXUIElementGetPid(element, &pid)
		guard status == .success else { return nil }
		return Int32(pid)
	}

	func parentElement(_ element: AXUIElement) -> AXUIElement? {
		guard let value = copyAttribute(element, attribute: kAXParentAttribute as CFString) else {
			return nil
		}
		return asAXElement(value)
	}

	func sameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
		CFEqual(lhs as CFTypeRef, rhs as CFTypeRef)
	}

	func isElement(_ element: AXUIElement, descendantOf ancestor: AXUIElement) -> Bool {
		var current: AXUIElement? = element
		var depth = 0
		while let candidate = current, depth < 20 {
			if sameElement(candidate, ancestor) {
				return true
			}
			current = parentElement(candidate)
			depth += 1
		}
		return false
	}

	func hasAncestorRole(_ element: AXUIElement, role: String) -> Bool {
		ancestor(of: element, role: role) != nil
	}

	/// The element itself or its nearest ancestor with `role`.
	func ancestor(of element: AXUIElement, role: String) -> AXUIElement? {
		var current: AXUIElement? = element
		var depth = 0
		while let candidate = current, depth < 30 {
			if stringAttribute(candidate, attribute: kAXRoleAttribute as CFString) == role { return candidate }
			current = parentElement(candidate)
			depth += 1
		}
		return nil
	}

	/// Standard AX actions are stable API names. Custom actions arrive as multi-line
	/// `Name:…\nTarget:…\nSelector:…` descriptions, of which only the name is useful.
	func readableActionName(_ raw: String) -> String? {
		if raw.hasPrefix("AX") { return raw }
		let firstLine = raw.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? raw
		let named = firstLine.hasPrefix("Name:") ? String(firstLine.dropFirst("Name:".count)) : firstLine
		let trimmed = named.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	func actionNames(_ element: AXUIElement) -> [String] {
		var actionsValue: CFArray?
		let status = AXUIElementCopyActionNames(element, &actionsValue)
		guard status == .success else { return [] }
		guard let actionsArray = actionsValue as? [AnyObject] else { return [] }
		return actionsArray.compactMap { ($0 as? String).flatMap(readableActionName) }
	}

	/// Errors of AXUIElementPerformAction that prove the request never reached the app. Others
	/// (a timeout while the app is busy handling it, a generic failure Finder's own toolbar
	/// returns for presses that landed) say nothing about whether it ran, and doing it again
	/// could run it twice.
	static func actionNeverArrived(_ status: AXError) -> Bool {
		[.invalidUIElement, .illegalArgument, .notImplemented].contains(status)
	}

	func supportsAction(_ element: AXUIElement, action: CFString) -> Bool {
		actionNames(element).contains(action as String)
	}

	func copyAttribute(_ element: AXUIElement, attribute: CFString) -> AnyObject? {
		var value: AnyObject?
		let status = AXUIElementCopyAttributeValue(element, attribute, &value)
		guard status == .success else { return nil }
		return value
	}

	func boolAttribute(_ element: AXUIElement, attribute: CFString) -> Bool? {
		guard let value = copyAttribute(element, attribute: attribute) else { return nil }
		if let boolValue = value as? Bool {
			return boolValue
		}
		if let number = value as? NSNumber {
			return number.boolValue
		}
		return nil
	}

	func stringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
		copyAttribute(element, attribute: attribute) as? String
	}

	/// One comparable string for an accessibility fact, so the same attribute can be
	/// diffed across an action whatever type it carries.
	func attributeSignature(_ element: AXUIElement, attribute: CFString) -> String? {
		guard let value = copyAttribute(element, attribute: attribute) else { return nil }
		if let text = value as? String { return text }
		if let number = value as? NSNumber { return number.stringValue }
		guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .cfRange else { return nil }
		var range = CFRange()
		guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
		return "\(range.location),\(range.length)"
	}

	// Secure fields can expose plaintext through AX value in non-native apps,
	// and serialized values flow into the model conversation. Never emit them.
	func isSecureTextElement(role: String, subrole: String) -> Bool {
		role == "AXSecureTextField" || subrole == "AXSecureTextField"
	}

	/// A secure field or anything inside it: its field editor and text area carry the typed
	/// text without the secure subrole.
	func isInSecureField(_ element: AXUIElement) -> Bool {
		var current: AXUIElement? = element
		while let candidate = current {
			if isSecureTextElement(role: stringAttribute(candidate, attribute: kAXRoleAttribute as CFString) ?? "", subrole: stringAttribute(candidate, attribute: kAXSubroleAttribute as CFString) ?? "") { return true }
			current = parentElement(candidate)
		}
		return false
	}

	/// Toggles carry their state in a numeric AXValue, so a value is rendered whatever
	/// its type: an agent that cannot read `0`/`1` cannot tell a checked box from a clear one.
	func displayValue(_ element: AXUIElement, role: String, subrole: String) -> String {
		if isSecureTextElement(role: role, subrole: subrole) { return "" }
		guard let value = copyAttribute(element, attribute: kAXValueAttribute as CFString) else { return "" }
		if let text = value as? String { return text }
		return (value as? NSNumber)?.stringValue ?? ""
	}

	// kAXSheetsAttribute is unsupported (-25205) on recent macOS; sheets are
	// exposed only as AXSheet-role children. Merge both sources so sheet
	// discovery works across versions.
	func sheetElements(of window: AXUIElement) -> [AXUIElement] {
		var sheets = axElementArray(window, attribute: "AXSheets" as CFString)
		for child in axElementArray(window, attribute: kAXChildrenAttribute as CFString) {
			guard (stringAttribute(child, attribute: kAXRoleAttribute as CFString) ?? "") == "AXSheet" else { continue }
			if !sheets.contains(where: { CFEqual($0, child) }) { sheets.append(child) }
		}
		return sheets
	}

	func axElementArray(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
		guard let value = copyAttribute(element, attribute: attribute) else { return [] }
		if let array = value as? [AXUIElement] {
			return array
		}
		if let anyArray = value as? [AnyObject] {
			return anyArray.compactMap(asAXElement)
		}
		return []
	}

	func axElementArrayIfPresent(_ element: AXUIElement, attribute: CFString) -> [AXUIElement]? {
		var value: CFTypeRef?
		let status = AXUIElementCopyAttributeValue(element, attribute, &value)
		guard status == .success, let value else { return nil }
		if let array = value as? [AXUIElement] {
			return array
		}
		if let anyArray = value as? [AnyObject] {
			return anyArray.compactMap(asAXElement)
		}
		return []
	}

	func asAXElement(_ value: AnyObject) -> AXUIElement? {
		let cfValue = value as CFTypeRef
		guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
		return unsafeDowncast(cfValue, to: AXUIElement.self)
	}

	func pointAttribute(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
		guard let value = copyAttribute(element, attribute: attribute) else { return nil }
		let cfValue = value as CFTypeRef
		guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
		let axValue = unsafeDowncast(cfValue, to: AXValue.self)
		guard AXValueGetType(axValue) == .cgPoint else { return nil }
		var point = CGPoint.zero
		guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
		return point
	}

	func sizeAttribute(_ element: AXUIElement, attribute: CFString) -> CGSize? {
		guard let value = copyAttribute(element, attribute: attribute) else { return nil }
		let cfValue = value as CFTypeRef
		guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
		let axValue = unsafeDowncast(cfValue, to: AXValue.self)
		guard AXValueGetType(axValue) == .cgSize else { return nil }
		var size = CGSize.zero
		guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
		return size
	}

	func frameForWindow(_ window: AXUIElement) -> CGRect {
		let origin = pointAttribute(window, attribute: kAXPositionAttribute as CFString) ?? .zero
		let size = sizeAttribute(window, attribute: kAXSizeAttribute as CFString) ?? .zero
		return CGRect(origin: origin, size: size)
	}
}
