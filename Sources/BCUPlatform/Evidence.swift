import AppKit
import BCUCore

extension Platform {
	/// The facts an element tells about itself, in the order they are reported.
	static let evidenceAttributes: [(field: String, attribute: String)] = [
		("value", kAXValueAttribute),
		("selected", "AXSelected"),
		("focused", kAXFocusedAttribute),
		("selection", kAXSelectedTextRangeAttribute),
		("selectedText", kAXSelectedTextAttribute),
	]

	/// Longest evidence value reported back; comparison always uses the full string.
	static let evidenceReportLimit = 40

	/// An item in a menu reports its highlight as AXSelected, and AppKit leaves it on the item
	/// last pressed; it is not a state the press set. A menu bar item's AXSelected is its
	/// menu being open, which is.
	func evidenceSnapshot(_ element: AXUIElement) -> [String: String]? {
		guard let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) else { return nil }
		var snapshot: [String: String] = [:]
		for entry in Self.evidenceAttributes where !(entry.field == "selected" && role == kAXMenuItemRole as String) {
			if let value = attributeSignature(element, attribute: entry.attribute as CFString) { snapshot[entry.field] = value }
		}
		return snapshot
	}

	func evidenceExcerpt(_ value: String) -> String {
		let flat = value.replacingOccurrences(of: "\n", with: " ")
		return flat.count > Self.evidenceReportLimit ? String(flat.prefix(Self.evidenceReportLimit)) + "\u{2026}" : flat
	}

	func evidenceDifference(before: [String: String], after: [String: String]) -> ActEvidence? {
		for entry in Self.evidenceAttributes {
			let from = before[entry.field] ?? ""
			let to = after[entry.field] ?? ""
			guard from != to else { continue }
			return ActEvidence(source: .ax, field: ActEvidence.Field(rawValue: entry.field), from: evidenceExcerpt(from), to: evidenceExcerpt(to))
		}
		return nil
	}

	/// Accessibility facts settle a run loop turn after delivery, so the platform waits for
	/// the change instead of guessing a sleep. A dead element yields no evidence at all.
	func evidenceAfterAction(_ element: AXUIElement, before: [String: String], timeout: TimeInterval) -> [String: String]? {
		let deadline = Date().addingTimeInterval(timeout)
		while true {
			guard let after = evidenceSnapshot(element) else { return nil }
			if evidenceDifference(before: before, after: after) != nil || Date() >= deadline { return after }
			usleep(20_000)
		}
	}

	/// Elements whose press flips a value. The projection (BCUCore) promises these the `toggle`
	/// capability from the same role and subrole families.
	func isToggleLike(_ element: AXUIElement) -> Bool {
		let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
		let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
		let roles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXDisclosureTriangle", "AXToggleButton"]
		let subroles: Set<String> = ["AXSwitch", "AXSegment"]
		return roles.contains(role) || subroles.contains(subrole)
	}

	func focusedWindowSummary(pid: Int32) -> String {
		let app = AXUIElementCreateApplication(pid)
		guard let element = copyAttribute(app, attribute: kAXFocusedWindowAttribute as CFString).flatMap(asAXElement) else { return "none" }
		let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
		let title = stringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? ""
		return "\(role):\(title)"
	}

	/// Scroll bars where the element has them, plus where its content sits relative to it:
	/// web scroll areas expose no scroll bar, and Chromium clips the frames of their direct
	/// children to the area, so the first chain of descendants is followed to the leaf
	/// that actually moves.
	func scrollPositionSignature(_ element: AXUIElement) -> String {
		let names: [CFString] = ["AXVerticalScrollBar" as CFString, "AXHorizontalScrollBar" as CFString, kAXValueAttribute as CFString]
		var parts = names.map { String(describing: copyAttribute(element, attribute: $0) ?? "" as CFTypeRef) }
		guard let origin = frameForElement(element)?.origin else { return parts.joined(separator: "|") }
		var content = axElementArray(element, attribute: kAXChildrenAttribute as CFString).first
		for _ in 0..<4 {
			guard let current = content else { break }
			if let frame = frameForElement(current) { parts.append("\(frame.minX - origin.x),\(frame.minY - origin.y)") }
			content = axElementArray(current, attribute: kAXChildrenAttribute as CFString).first
		}
		return parts.joined(separator: "|")
	}

	/// Whether the element carries a fact a press would move: value, selection or
	/// selected state. Focus alone is not one; bcu itself moves it to deliver input.
	func hasReadableEvidence(_ element: AXUIElement) -> Bool {
		guard let facts = evidenceSnapshot(element) else { return false }
		return facts.keys.contains { $0 != "focused" }
	}

	/// Bounded content-area diff; captures omit the cursor and title bar.
	/// Screen evidence: how long to wait for the window to repaint, how far a channel must
	/// move for a pixel to count, and the share of content pixels that must move. The title
	/// bar is left out; its height is in points.
	static let screenEvidenceTimeout: TimeInterval = 0.6

	static let screenEvidencePollMicros: UInt32 = 80_000

	static let screenEvidenceChannelDelta = 30

	static let screenEvidenceChangedShare = 0.005

	static let screenEvidenceTitleBarPoints = 28.0

	func screenChanged(before: CGImage, windowId: UInt32, timeout: TimeInterval = Platform.screenEvidenceTimeout) -> Bool {
		func ratio(_ after: CGImage) -> Double {
			let width = min(before.width, after.width), height = min(before.height, after.height)
			let scale = currentWindowBounds(windowId: windowId).map { $0.width > 0 ? Double(before.width) / Double($0.width) : 1 } ?? 1
			let titleBarPixels = Int((Self.screenEvidenceTitleBarPoints * scale).rounded())
			guard width > 0, height > titleBarPixels, let bd = before.dataProvider?.data, let ad = after.dataProvider?.data,
				let bp = CFDataGetBytePtr(bd), let ap = CFDataGetBytePtr(ad) else { return 0 }
			var changed = 0
			for y in titleBarPixels..<height { for x in 0..<width {
				let bi = y * before.bytesPerRow + x * 4, ai = y * after.bytesPerRow + x * 4
				if (0..<3).contains(where: { abs(Int(bp[bi + $0]) - Int(ap[ai + $0])) > Self.screenEvidenceChannelDelta }) { changed += 1 }
			} }
			return Double(changed) / Double(width * (height - titleBarPixels))
		}
		func captureAfter(_ deadline: Date) -> CGImage? {
			let semaphore = DispatchSemaphore(value: 0)
			let result = Handoff<CGImage?>(nil)
			DispatchQueue.global().async {
				result.value = try? self.captureWindow(windowId: windowId).image
				semaphore.signal()
			}
			guard semaphore.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else { return nil }
			return result.value
		}
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			guard let after = captureAfter(deadline) else { return false }
			if ratio(after) >= Self.screenEvidenceChangedShare { return true }
			usleep(min(Self.screenEvidencePollMicros, max(1, UInt32(max(0, deadline.timeIntervalSinceNow) * 1_000_000))))
		}
		return false
	}
}
