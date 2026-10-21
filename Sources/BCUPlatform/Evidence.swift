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

	/// The newest value or title an element of `root` announced since `cursor`, as it reads
	/// now: a press whose control keeps no fact of its own (a calculator key) moves one
	/// elsewhere in the window. A secure field's value is never evidence.
	func announcement(_ notifications: AppNotifications, since cursor: UInt64, in root: AXUIElement) -> ActEvidence? {
		for event in notifications.events(since: cursor).reversed() {
			guard let element = event.element?.element, isElement(element, descendantOf: root) else { continue }
			let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
			let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
			guard subrole != kAXSecureTextFieldSubrole as String else { continue }
			let title = event.notification == kAXTitleChangedNotification ? stringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? "" : ""
			let text = title.isEmpty ? displayValue(element, role: role, subrole: subrole) : title
			return ActEvidence(source: .ax, field: .announced, to: evidenceExcerpt(text))
		}
		return nil
	}

	/// What a press does to the element's value; the projection gives the same elements `toggle`.
	func pressEffect(_ element: AXUIElement) -> PressEffect? {
		BCUCore.pressEffect(role: stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? "", subrole: stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? "")
	}

	/// A radio, tab or segment that is selected: pressing it asks for what already holds.
	func isAlreadySelected(_ element: AXUIElement, before: [String: String]?) -> Bool {
		before?["value"] == "1" && pressEffect(element) == .selects
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

	/// Screen evidence: how long to wait for the window to repaint, how often to capture it
	/// meanwhile, how far a channel must move for a pixel to count, and the share of content
	/// pixels that must move. The title bar is left out; its height is in points.
	static let screenEvidenceTimeout: TimeInterval = 0.6
	static let screenEvidenceInterval: TimeInterval = 0.08
	static let screenEvidenceChannelDelta = 30
	static let screenEvidenceChangedShare = 0.005
	static let screenEvidenceTitleBarPoints = 28.0

	/// The window before an action whose only evidence may be its pixels; nil when it cannot
	/// be captured, and the action is then judged without screen evidence.
	func screenBaseline(windowId: UInt32) -> ScreenBaseline? {
		(try? captureWindow(windowId: windowId)).map { ScreenBaseline(image: $0.capture.image, capturer: $0.capturer) }
	}

	/// Whether the window's content area changed since the baseline within the evidence
	/// timeout. Nothing announces that pixels changed, so this is the one place that captures
	/// on an interval; the window is looked up once, in the baseline, and only captured here.
	func screenChanged(since baseline: ScreenBaseline, deliveredAt: Date) -> Bool {
		let before = baseline.image
		let pixelsPerPoint = baseline.capturer.frame.width > 0 ? Double(before.width) / baseline.capturer.frame.width : 1
		let titleBarPixels = Int((Self.screenEvidenceTitleBarPoints * pixelsPerPoint).rounded())
		func changedShare(_ after: CGImage) -> Double {
			let width = min(before.width, after.width), height = min(before.height, after.height)
			guard width > 0, height > titleBarPixels, let bd = before.dataProvider?.data, let ad = after.dataProvider?.data,
				let bp = CFDataGetBytePtr(bd), let ap = CFDataGetBytePtr(ad) else { return 0 }
			var changed = 0
			for y in titleBarPixels..<height { for x in 0..<width {
				let bi = y * before.bytesPerRow + x * 4, ai = y * after.bytesPerRow + x * 4
				if (0..<3).contains(where: { abs(Int(bp[bi + $0]) - Int(ap[ai + $0])) > Self.screenEvidenceChannelDelta }) { changed += 1 }
			} }
			return Double(changed) / Double(width * (height - titleBarPixels))
		}
		let deadline = deliveredAt.addingTimeInterval(Self.screenEvidenceTimeout)
		while Date() < deadline {
			guard let after = try? captureAgain(baseline.capturer, within: deadline.timeIntervalSinceNow) else { return false }
			if changedShare(after) >= Self.screenEvidenceChangedShare { return true }
			Thread.sleep(until: min(deadline, Date().addingTimeInterval(Self.screenEvidenceInterval)))
		}
		return false
	}
}

/// A window's pixels before an action, with the capturer that looked the window up.
struct ScreenBaseline: Sendable {
	let image: CGImage
	let capturer: WindowCapturer
}
