import AppKit

let axScrollDownAction = "AXScrollDown"
let axScrollUpAction = "AXScrollUp"
let axScrollLeftAction = "AXScrollLeft"
let axScrollRightAction = "AXScrollRight"

extension Platform {
	/// Finds an element again from what it looked like, when its accessibility object was replaced.
	func refindElement(_ snapshot: ElementSnapshot, pid: Int32, windowId: UInt32) -> AXUIElement? {
		guard let window = resolveRoot(pid: pid, windowId: windowId) else { return nil }
		let targetCenter = CGPoint(x: snapshot.rect.midX, y: snapshot.rect.midY)
		let candidates = collectDescendants(startingAt: window, maxDepth: 8).filter { candidate in
			let role = stringAttribute(candidate, attribute: kAXRoleAttribute as CFString) ?? ""
			guard role == snapshot.role else { return false }
			let identifier = stringAttribute(candidate, attribute: "AXIdentifier" as CFString) ?? ""
			if !snapshot.identifier.isEmpty { return identifier == snapshot.identifier }
			let subrole = stringAttribute(candidate, attribute: kAXSubroleAttribute as CFString) ?? ""
			let title = stringAttribute(candidate, attribute: kAXTitleAttribute as CFString) ?? ""
			let description = stringAttribute(candidate, attribute: kAXDescriptionAttribute as CFString) ?? ""
			let value = displayValue(candidate, role: role, subrole: subrole)
			return normalizedLabel([title, description, value].joined(separator: " ")) == snapshot.label
		}
		return candidates.min { left, right in
			let leftFrame = frameForElement(left) ?? .zero
			let rightFrame = frameForElement(right) ?? .zero
			let leftDistance = hypot(leftFrame.midX - targetCenter.x, leftFrame.midY - targetCenter.y)
			let rightDistance = hypot(rightFrame.midX - targetCenter.x, rightFrame.midY - targetCenter.y)
			return leftDistance < rightDistance
		}
	}

	func hitTestElement(at point: CGPoint) -> AXUIElement? {
		let systemWide = AXUIElementCreateSystemWide()
		var hitElement: AXUIElement?
		let status = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hitElement)
		guard status == .success, let hitElement else { return nil }
		return hitElement
	}

	/// The element a coordinate lands on inside the target root, climbed at most three levels
	/// to the control that owns it (the deepest hit is usually a label). System-wide hit
	/// testing sees whatever is on top, so a hit outside the target, or on the window itself,
	/// falls back to the smallest element of the root that contains the point.
	func coordinateSubject(at point: CGPoint, pid: Int32, windowId: UInt32) -> AXUIElement? {
		func isWindowOrApp(_ element: AXUIElement) -> Bool {
			[kAXWindowRole, kAXApplicationRole].contains(stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? "")
		}
		var hit = hitTestElement(at: point).flatMap { pidForElement($0) == pid && !isWindowOrApp($0) ? $0 : nil }
		if hit == nil, let root = resolveRoot(pid: pid, windowId: windowId) {
			hit = collectDescendants(startingAt: root, maxDepth: 20)
				.filter { !isWindowOrApp($0) && (frameForElement($0)?.contains(point) ?? false) }
				.min { (frameForElement($0).map { $0.width * $0.height } ?? .infinity) < (frameForElement($1).map { $0.width * $0.height } ?? .infinity) }
		}
		var candidate = hit
		for _ in 0...3 {
			guard let current = candidate, !isWindowOrApp(current) else { break }
			if supportsAction(current, action: kAXPressAction as CFString) { return current }
			candidate = parentElement(current)
		}
		return hit
	}

	/// Controls whose press does not depend on where inside them it lands, so a plain
	/// click at a point over one is the same action as pressing its ref.
	static let discreteControlRoles: Set<String> = [
		kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole,
		kAXMenuItemRole, kAXDisclosureTriangleRole,
	]

	func scrollActionNames(scrollX: Int, scrollY: Int) -> [CFString] {
		var actions: [CFString] = []
		if scrollY > 0 { actions.append(axScrollDownAction as CFString) }
		if scrollY < 0 { actions.append(axScrollUpAction as CFString) }
		if scrollX > 0 { actions.append(axScrollRightAction as CFString) }
		if scrollX < 0 { actions.append(axScrollLeftAction as CFString) }
		return actions
	}

	func supportsAnyScrollAction(_ element: AXUIElement) -> Bool {
		let actions = Set(actionNames(element))
		return actions.contains(axScrollDownAction) || actions.contains(axScrollUpAction) || actions.contains(axScrollLeftAction) || actions.contains(axScrollRightAction)
	}

	/// Scrolls with the element's own scroll actions, or those of the nearest ancestor of the
	/// same process that has them. False when nothing in the chain scrolled.
	func performScrollActionOrAncestor(startingAt element: AXUIElement, targetPid: Int32, scrollX: Int, scrollY: Int) -> Bool {
		let actions = scrollActionNames(scrollX: scrollX, scrollY: scrollY)
		guard !actions.isEmpty else { return false }
		var current: AXUIElement? = element
		var depth = 0

		while let candidate = current, depth < 10 {
			if let pid = pidForElement(candidate), pid != targetPid { return false }
			var didScroll = false
			for action in actions where supportsAction(candidate, action: action) {
				if AXUIElementPerformAction(candidate, action) == .success { didScroll = true }
			}
			if didScroll { return true }
			current = parentElement(candidate)
			depth += 1
		}
		return false
	}
}
