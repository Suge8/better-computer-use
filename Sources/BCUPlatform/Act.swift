import AppKit

extension Bridge {
	func act(_ request: [String: Any]) throws -> [String: Any] {
		let lookId = try stringArg(request, "lookId")
		guard let record = lookRecord(for: lookId) else {
			throw BridgeFailure(message: "Look id '\(lookId)' is no longer available", code: "stale_look")
		}
		let pid = Int32(try intArg(request, "pid"))
		let action = try stringArg(request, "action")
		let target = request["target"] as? [String: Any] ?? [:]
		let params = request["params"] as? [String: Any] ?? [:]
		let policy = optionalStringArg(request, "policy") ?? "default"
		let deferRootDelta = boolArg(request, "deferRootDelta") ?? false
		let delivery = policy == "background" ? "pid" : ((params["delivery"] as? String) == "pid" ? "pid" : "hid")
		var holdsPhysicalInput = false
		func acquirePhysicalInputIfNeeded() {
			if delivery == "hid" && !holdsPhysicalInput {
				physicalInputLock.lock()
				holdsPhysicalInput = true
			}
		}
		defer { if holdsPhysicalInput { physicalInputLock.unlock() } }
		let pressLike = action == "press" || action == "click"
		var performed: [String: Any] = ["delivery": delivery]
		var element: AXUIElement?
		var rawPoint: CGPoint?
		// The element the outcome is judged on, and whether the pointer provably reached it.
		var evidenceElement: AXUIElement?
		var beforeEvidence: [String: String]?
		var hitVerified = false
		var screenBefore: CGImage?
		let eventsLive = !deferRootDelta && ensureRootObserver(pid: pid)
		var beforeFrontmostPid: pid_t?
		var eventCursor: UInt64 = 0
		var beforeRootSnapshot: [String: [String: Any]] = [:]
		var beforeCgSignature: Set<UInt32> = []
		var beforeSheetCount = 0
		var beforeFocusedWindow = ""
		/// The state the action's effect is measured against. Focusing the target for input is
		/// bcu's own doing, so it is taken into the baseline rather than counted as an effect.
		func takeRootBaseline() {
			beforeFrontmostPid = deferRootDelta ? nil : NSWorkspace.shared.frontmostApplication?.processIdentifier
			eventCursor = eventsLive ? rootEventCursor(pid: pid) : 0
			beforeRootSnapshot = deferRootDelta ? [:] : rootMetadataSnapshot(pid: pid)
			beforeCgSignature = deferRootDelta ? [] : cgRootSignature(pid: pid)
			beforeSheetCount = resolveRoot(pid: pid, windowId: record.windowId).map { sheetElements(of: $0).count } ?? 0
			beforeFocusedWindow = focusedWindowSummary(pid: pid)
		}
		func takeBaseline() {
			takeRootBaseline()
			if let subject = element ?? evidenceElement { beforeEvidence = evidenceSnapshot(subject) }
		}
		takeBaseline()
		func finish(_ response: [String: Any]) -> [String: Any] {
			if deferRootDelta { return response }
			return attachRootDelta(to: response, before: beforeRootSnapshot, beforeFrontmostPid: beforeFrontmostPid, pid: pid, eventsLive: eventsLive, eventCursor: eventCursor, beforeCgSignature: beforeCgSignature)
		}
		/// Input posted to a pid reaches only its key window. The handoff is taken into the
		/// baseline, so it is never mistaken for the action's own effect.
		func focusTargetForBackgroundInput() throws {
			guard delivery == "pid", policy != "ax_only", !(params["preserveFocus"] as? Bool ?? false),
				try focusWindowWithoutRaise(pid: pid, windowId: record.windowId)
			else { return }
			performed["focusedWindow"] = true
			takeBaseline()
		}

		if let ref = target["ref"] as? String {
			var refound = false
			let cached = refStore.element(for: ref)
			let cachedIsLive = cached.map {
				stringAttribute($0, attribute: kAXRoleAttribute as CFString) != nil && frameForElement($0) != nil
			} ?? false
			var resolved: AXUIElement?
			if cachedIsLive {
				resolved = cached
			} else {
				resolved = refindElement(ref: ref, pid: pid, windowId: record.windowId)
				refound = resolved != nil
				// Geometry is missing for whole families of live elements — the menu bar of a
				// background app draws nothing — so an element that still answers accessibility
				// is the target even when nothing can be refound for it.
				if resolved == nil, let cached, stringAttribute(cached, attribute: kAXRoleAttribute as CFString) != nil { resolved = cached }
			}
			guard let stored = resolved else {
				throw BridgeFailure(message: "Element reference is stale", code: "stale_ref")
			}
			if refound { performed["refound"] = true }
			element = stored
			evidenceElement = stored
			beforeEvidence = evidenceSnapshot(stored)
		} else if let xNumber = target["x"] as? NSNumber, let yNumber = target["y"] as? NSNumber {
			guard record.hasImage else {
				throw BridgeFailure(message: "Coordinate targeting is unavailable for this outline-only root", code: "coordinate_unavailable_for_root")
			}
			let point = lookPoint(record: record, x: xNumber.doubleValue, y: yNumber.doubleValue)
			rawPoint = point
			// A plain click over a native discrete control takes the same ladder as its ref,
			// starting from a background AXPress. Web content keeps the pointer: Chromium's own
			// pointer path is exact, and its AXPress cannot be told apart from a no-op.
			let plainClick = pressLike && (params["button"] as? String ?? "left") == "left" && ((params["clickCount"] as? NSNumber)?.intValue ?? 1) == 1
			if plainClick, let control = coordinateSubject(at: point, pid: pid, windowId: record.windowId),
				Self.discreteControlRoles.contains(stringAttribute(control, attribute: kAXRoleAttribute as CFString) ?? ""),
				supportsAction(control, action: kAXPressAction as CFString),
				!hasAncestorRole(control, role: "AXWebArea")
			{
				element = control
				evidenceElement = control
				beforeEvidence = evidenceSnapshot(control)
			}
		} else {
			throw BridgeFailure(message: "act target must include ref or x/y", code: "invalid_args")
		}

		func coordinatePoint() throws -> CGPoint {
			if let rawPoint { return rawPoint }
			if let element, let frame = frameForElement(element) {
				return CGPoint(x: frame.midX, y: frame.midY)
			}
			throw BridgeFailure(message: "No coordinate grounding is available", code: "coordinate_unavailable")
		}

		func animateCursor(at point: CGPoint) {
			guard supportsAgentCursor,
				(request["cursorOverlay"] as? Bool ?? true),
				delivery == "pid",
				policy != "ax_only",
				["press", "click", "moveMouse", "scroll", "drag"].contains(action)
			else { return }
			Task { @MainActor in AgentCursor.shared.animate(to: point, above: record.windowId) }
		}

		/// Activation is asynchronous: a menu bar item has no geometry until it belongs to the
		/// frontmost app, and that geometry is the signal to wait for. An item inside a closed
		/// menu has none either way, so the menu bar item above it is watched instead. The
		/// switch is bcu's own doing, so the baseline is taken after it.
		func activateForMenuBar(_ item: AXUIElement) {
			guard let app = NSRunningApplication(processIdentifier: pid) else { return }
			performed["activated"] = app.activate()
			let barItem = ancestor(of: item, role: kAXMenuBarItemRole as String) ?? item
			let deadline = Date().addingTimeInterval(1.5)
			while Date() < deadline, (frameForElement(barItem)?.width ?? 0) <= 0 { usleep(20_000) }
			takeRootBaseline()
			beforeEvidence = evidenceSnapshot(item)
		}

		/// AppKit validates a menu's items only when the menu opens, so an item in a closed menu
		/// reports whatever enabled state it had last time, and a press on an item that is
		/// really disabled is accepted and dropped. The menus down to the item are opened first;
		/// that is bcu's own doing, so only the event cursor moves past it, and the root
		/// snapshot, taken before, sees the menus closed again after the press.
		func openMenusAbove(_ item: AXUIElement) throws -> AXUIElement? {
			var openers: [AXUIElement] = []
			var current = parentElement(item)
			while let candidate = current {
				let role = stringAttribute(candidate, attribute: kAXRoleAttribute as CFString) ?? ""
				if role == kAXMenuBarRole as String { break }
				if role == kAXMenuItemRole as String || role == kAXMenuBarItemRole as String { openers.insert(candidate, at: 0) }
				current = parentElement(candidate)
			}
			let title = stringAttribute(item, attribute: kAXTitleAttribute as CFString) ?? ""
			var opened: AXUIElement?
			for (index, opener) in openers.enumerated() {
				let shown = index + 1 < openers.count ? openers[index + 1] : item
				if (frameForElement(shown)?.width ?? 0) > 0 { continue }
				opened = opened ?? shown
				let observed = ensureRootObserver(pid: pid)
				let cursor = rootEventCursor(pid: pid)
				guard AXUIElementPerformAction(opener, kAXPressAction as CFString) == .success else {
					throw BridgeFailure(message: "The menu holding '\(title)' did not open", code: "input_failed")
				}
				// AppKit posts AXMenuOpened once the menu is validated and tracking; the menu's
				// geometry can appear before that, so it is only the signal without an observer.
				func isOpen() -> Bool {
					observed
						? rootEvents(pid: pid, since: cursor).contains { $0.notification == "AXMenuOpened" }
						: (frameForElement(shown)?.width ?? 0) > 0
				}
				let deadline = Date().addingTimeInterval(1.0)
				while !isOpen() {
					guard Date() < deadline else {
						throw BridgeFailure(message: "The menu holding '\(title)' did not open", code: "input_failed")
					}
					usleep(20_000)
				}
			}
			if eventsLive { eventCursor = rootEventCursor(pid: pid) }
			if opened != nil { performed["openedMenus"] = true }
			if boolAttribute(item, attribute: kAXEnabledAttribute as CFString) == false {
				_ = AXUIElementPerformAction(item, kAXCancelAction as CFString)
				throw BridgeFailure(message: "The menu item '\(title)' is disabled", code: "element_disabled")
			}
			return opened
		}

		/// A pressed menu item closes its menus a moment later; the roots are judged once the
		/// menus bcu opened are gone, so they are neither an appeared nor a closed root.
		func awaitMenuClosed(_ shown: AXUIElement) {
			let deadline = Date().addingTimeInterval(1.0)
			while Date() < deadline, (frameForElement(shown)?.width ?? 0) > 0 { usleep(20_000) }
		}

		func focusTargetForPhysicalInput() {
			guard delivery == "hid" else { return }
			if let app = NSRunningApplication(processIdentifier: pid), !app.isActive {
				performed["activated"] = app.activate()
			}
			if let window = resolveRoot(pid: pid, windowId: record.windowId) {
				_ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
				_ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
				performed["raised"] = AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
			}
			// Activation lands asynchronously; the baseline waits for it so the switch is
			// never read as the action's effect.
			let deadline = Date().addingTimeInterval(0.5)
			repeat { usleep(20_000) } while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < deadline
			takeRootBaseline()
		}

		func preflight(_ point: CGPoint) throws {
			guard let element else { return }
			for attempt in 0..<4 {
				guard let hit = hitTestElement(at: point) else { return }
				if sameElement(hit, element) || isElement(hit, descendantOf: element) || isElement(element, descendantOf: hit) {
					hitVerified = true
					return
				}
				let role = stringAttribute(hit, attribute: kAXRoleAttribute as CFString) ?? ""
				if role == "AXWindow" || role == "AXApplication" { return }
				if delivery == "hid" && attempt < 3 {
					focusTargetForPhysicalInput()
					usleep(20_000)
					continue
				}
				throw BridgeFailure(message: "Target is occluded by \(payloadNode(element: hit))", code: "occluded_target")
			}
		}

		func executeCoordinates(_ point: CGPoint) throws {
			guard element != nil || record.hasImage else {
				throw BridgeFailure(message: "Coordinate grounding is unavailable for this outline-only root", code: "coordinate_unavailable_for_root")
			}
			performed["grounding"] = "coordinates"
			if delivery == "pid" { performed["verification"] = "caller_required" }
			let subject = element ?? coordinateSubject(at: point, pid: pid, windowId: record.windowId)
			let webTarget = subject.map { hasAncestorRole($0, role: "AXWebArea") } ?? false
			let readable = subject.map(hasReadableEvidence) ?? false
			// Screen evidence is reserved for a point whose resolved subject has no AX fact
			// that a press would move; see docs/architecture.md.
			let screenTarget = pressLike && !webTarget && !readable
			if element == nil, pressLike, readable, let subject {
				evidenceElement = subject
				beforeEvidence = evidenceSnapshot(subject)
				hitVerified = true
			}
			acquirePhysicalInputIfNeeded()
			if delivery == "pid", !webTarget {
				// A stock NSView drops the first click on an inactive app; this makes the
				// target app take the click without becoming the front app.
				try SkyLight.activateWithoutRaise(windowId: record.windowId)
				performed["backgroundActivation"] = true
			} else {
				focusTargetForPhysicalInput()
				try focusTargetForBackgroundInput()
			}
			if screenTarget, let before = try? captureWindow(windowId: record.windowId) { screenBefore = before.image }
			if delivery == "hid" { try preflight(point) }
			let route = SkyLight.PointerRoute(pid: pid, windowId: record.windowId, windowOrigin: record.windowFrame.origin)
			switch action {
			case "press", "click":
				animateCursor(at: point)
				try postMouseClick(at: point, pid: pid, route: route, button: mouseButton(params["button"] as? String ?? "left"), clickCount: max(1, min(3, (params["clickCount"] as? NSNumber)?.intValue ?? 1)), delivery: delivery)
			case "moveMouse":
				animateCursor(at: point)
				try postMouseMove(to: point, pid: pid, delivery: delivery)
			case "scroll":
				animateCursor(at: point)
				try postScrollWheel(at: point, deltaX: (params["scrollX"] as? NSNumber)?.intValue ?? 0, deltaY: (params["scrollY"] as? NSNumber)?.intValue ?? 0, pid: pid, route: route, delivery: delivery)
			case "drag":
				guard let rawPath = params["path"] as? [[String: Any]], rawPath.count >= 2 else {
					throw BridgeFailure(message: "drag requires path", code: "invalid_args")
				}
				let points = try rawPath.map { raw -> CGPoint in
					guard let x = (raw["x"] as? NSNumber)?.doubleValue, let y = (raw["y"] as? NSNumber)?.doubleValue else {
						throw BridgeFailure(message: "drag path entries require x and y", code: "invalid_args")
					}
					return lookPoint(record: record, x: x, y: y)
				}
				animateCursor(at: point)
				try postMouseDrag(points: points, pid: pid, delivery: delivery)
			default:
				throw BridgeFailure(message: "Action \(action) cannot use coordinate grounding", code: "invalid_args")
			}
		}

		func refreshElement() -> AXUIElement? {
			guard let ref = target["ref"] as? String,
				let refreshed = refindElement(ref: ref, pid: pid, windowId: record.windowId)
			else { return nil }
			element = refreshed
			performed["refound"] = true
			return refreshed
		}

		/// Judges the outcome on the evidence rules; see docs/architecture.md.
		func verdict() -> [String: Any] {
			let afterSheetCount = resolveRoot(pid: pid, windowId: record.windowId).map { sheetElements(of: $0).count } ?? beforeSheetCount
			let windowChanged = beforeFocusedWindow != focusedWindowSummary(pid: pid) || beforeSheetCount != afterSheetCount
			var outcome = "unknown"
			var verification: [String: Any]?
			// The element that was acted on speaks first: its own value, selection or focus
			// moving is proof no window-level summary can contradict.
			if let subject = element ?? evidenceElement, let before = beforeEvidence {
				let after = evidenceAfterAction(subject, before: before, timeout: 0.25)
				if let after, let difference = evidenceDifference(before: before, after: after) {
					outcome = "worked"
					verification = difference
				} else if pressLike, hitVerified, after?["focused"] == "1", !Set([kAXWindowRole, kAXApplicationRole]).contains(stringAttribute(subject, attribute: kAXRoleAttribute as CFString) ?? "") {
					// The pointer provably reached this element and it now holds keyboard focus:
					// a click that only places a caret leaves no other trace.
					outcome = "worked"
					verification = ["source": "focus", "field": "focused"]
				} else if pressLike, after != nil, before["value"] != nil, isToggleLike(subject) {
					outcome = "didnt"
					verification = ["source": "ax", "field": "value", "from": evidenceExcerpt(before["value"] ?? ""), "to": evidenceExcerpt(before["value"] ?? "")]
				}
			}
			if outcome == "unknown", windowChanged {
				outcome = "worked"
				verification = ["source": "root"]
			}
			// Weakest evidence, and the slowest to read: only for a subject with no AX fact.
			if outcome == "unknown", let screenBefore, screenChanged(before: screenBefore, windowId: record.windowId) {
				outcome = "worked"
				verification = ["source": "screen", "field": "changed"]
			}
			var response: [String: Any] = ["outcome": outcome, "performed": performed]
			if let verification { response["verification"] = verification }
			return response
		}

		if let element, pressLike {
			let elementRole = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
			let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXComboBox", "AXEditableText", "AXSecureTextField"]
			let inWebContent = hasAncestorRole(element, role: "AXWebArea")
			// Native text views place the caret only under a real pointer; Chromium's
			// AXPress focuses a web text field by itself.
			let requiresPointerFocus = textRoles.contains(elementRole) && !inWebContent
			// Only the frontmost app owns the menu bar. A background app accepts a press on a
			// menu bar item, or on an item of one of its menus, and does nothing with it, so
			// activation is a precondition, not a fallback.
			let inMenuBar = hasAncestorRole(element, role: kAXMenuBarRole as String)
			let requiresFrontmost = inMenuBar && !(NSRunningApplication(processIdentifier: pid)?.isActive ?? false)
			// Headless (`ax_only`) may not activate, so it gets the refusal as well instead of a
			// press that silently does nothing.
			if requiresFrontmost && policy != "foreground" {
				throw BridgeFailure(message: "The menu bar only answers in the frontmost app", code: "foreground_required")
			}
			if requiresPointerFocus && policy != "ax_only" {
				if policy == "foreground" {
					try executeCoordinates(coordinatePoint())
				} else {
					throw BridgeFailure(message: "Text input needs the real pointer to place its caret", code: "foreground_required")
				}
			} else if supportsAction(element, action: kAXPressAction as CFString) {
				if requiresFrontmost { activateForMenuBar(element) }
				let openedMenu = inMenuBar && elementRole == kAXMenuItemRole as String ? try openMenusAbove(element) : nil
				let cursorPoint = try? coordinatePoint()
				if !inWebContent, !hasReadableEvidence(element), let before = try? captureWindow(windowId: record.windowId) { screenBefore = before.image }
				var status = AXUIElementPerformAction(element, kAXPressAction as CFString)
				if status != .success, let refreshed = refreshElement(), supportsAction(refreshed, action: kAXPressAction as CFString) {
					status = AXUIElementPerformAction(refreshed, kAXPressAction as CFString)
				}
				if status == .success {
					performed["grounding"] = "description"
					performed["delivery"] = "ax"
					if let openedMenu { awaitMenuClosed(openedMenu) }
					if let cursorPoint { animateCursor(at: cursorPoint) }
					// The ladder rule of docs/architecture.md: only a press that provably changed
					// nothing (`didnt`) moves on to raw input. An unknown one stays put: Chromium's
					// AXPress already dispatches mousedown, mouseup and click, so pressing again
					// would apply the action twice.
					let axVerdict = verdict()
					if policy == "ax_only" || (axVerdict["outcome"] as? String) != "didnt" { return finish(axVerdict) }
					performed["delivery"] = delivery
					try executeCoordinates(coordinatePoint())
				} else {
					try executeCoordinates(coordinatePoint())
				}
			} else {
				try executeCoordinates(coordinatePoint())
			}
		} else if let element, action == "setText" {
			let text = params["text"] as? String ?? ""
			var targetElement = element
			var status = AXUIElementSetAttributeValue(targetElement, kAXValueAttribute as CFString, text as CFTypeRef)
			if status != .success, let refreshed = refreshElement() {
				targetElement = refreshed
				status = AXUIElementSetAttributeValue(targetElement, kAXValueAttribute as CFString, text as CFTypeRef)
			}
			if status == .success {
				performed["grounding"] = "description"
				performed["delivery"] = "ax"
				let value = stringAttribute(targetElement, attribute: kAXValueAttribute as CFString) ?? ""
				if value != text && policy != "foreground" {
					throw BridgeFailure(message: "The background accessibility value write was accepted but did not take effect", code: "foreground_required")
				}
				return finish([
					"outcome": value == text ? "worked" : "didnt",
					"performed": performed,
					"verification": ["source": "ax", "field": "value", "from": evidenceExcerpt(beforeEvidence?["value"] ?? ""), "to": evidenceExcerpt(value)],
				])
			}
			try executeCoordinates(coordinatePoint())
		} else if action == "typeText" {
			let preserveFocus = params["preserveFocus"] as? Bool ?? false
			try focusTargetForBackgroundInput()
			if let element {
				let focused = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
				if focused == .success { performed["focused"] = true }
			}
			acquirePhysicalInputIfNeeded()
			if delivery == "hid" && !preserveFocus { focusTargetForPhysicalInput() }
			let text = params["text"] as? String ?? ""
			try postUnicodeText(text, pid: pid, delivery: delivery)
			performed["grounding"] = "coordinates"
			if let element, !text.isEmpty {
				usleep(30_000)
				let beforeValue = beforeEvidence?["value"] ?? ""
				let afterValue = stringAttribute(element, attribute: kAXValueAttribute as CFString) ?? ""
				return finish([
					"outcome": afterValue != beforeValue ? "worked" : "didnt",
					"performed": performed,
					"verification": ["source": "ax", "field": "value", "from": evidenceExcerpt(beforeValue), "to": evidenceExcerpt(afterValue)],
				])
			}
		} else if action == "keypress" {
			let preserveFocus = params["preserveFocus"] as? Bool ?? false
			guard let keys = params["keys"] as? [String], !keys.isEmpty else {
				throw BridgeFailure(message: "keypress requires keys", code: "invalid_args")
			}
			try focusTargetForBackgroundInput()
			if let element {
				let focused = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
				if focused == .success { performed["focused"] = true }
				let normalizedKeys = keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
				if normalizedKeys.count == 2,
					normalizedKeys.last == "a",
					["cmd", "command", "meta"].contains(normalizedKeys.first ?? ""),
					let value = stringAttribute(element, attribute: kAXValueAttribute as CFString)
				{
					var range = CFRange(location: 0, length: (value as NSString).length)
					if let selection = AXValueCreate(.cfRange, &range),
						AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, selection) == .success
					{
						performed["selectionGrounding"] = "ax"
					}
				}
			}
			acquirePhysicalInputIfNeeded()
			if delivery == "hid" && !preserveFocus { focusTargetForPhysicalInput() }
			try postKeyPress(keys: keys, pid: pid, delivery: delivery)
			performed["grounding"] = "coordinates"
		} else if let element, action == "scroll" {
			let cursorPoint = try? coordinatePoint()
			let before = scrollPositionSignature(element)
			// Chromium exposes no scroll action on a scrollable element, and the actions of
			// its ancestors scroll the page instead, so web content scrolls by a wheel turn
			// over the element itself.
			let scrollsByWheel = hasAncestorRole(element, role: "AXWebArea") && !supportsAnyScrollAction(element)
			let result = scrollsByWheel ? [:] : performScrollActionOrAncestor(startingAt: element, targetPid: pid, scrollX: (params["scrollX"] as? NSNumber)?.intValue ?? 0, scrollY: (params["scrollY"] as? NSNumber)?.intValue ?? 0, steps: 1)
			if (result["scrolled"] as? Bool) == true {
				performed["grounding"] = "description"
				performed["delivery"] = "ax"
				if let cursorPoint { animateCursor(at: cursorPoint) }
			} else {
				try executeCoordinates(coordinatePoint())
			}
			// Web content reports the new offset a frame or two after the wheel turn.
			let deadline = Date().addingTimeInterval(0.3)
			while before == scrollPositionSignature(element) {
				guard Date() < deadline else { return finish(["outcome": "unknown", "performed": performed]) }
				usleep(20_000)
			}
			return finish(["outcome": "worked", "performed": performed, "verification": ["source": "ax", "field": "scroll"]])
		} else {
			try executeCoordinates(coordinatePoint())
		}

		return finish(verdict())
	}

	func actBatch(_ request: [String: Any]) throws -> [String: Any] {
		guard let actions = request["actions"] as? [[String: Any]], !actions.isEmpty, actions.count <= 20 else {
			throw BridgeFailure(message: "actBatch requires 1...20 actions", code: "invalid_args")
		}
		let pid = Int32(try intArg(actions[0], "pid"))
		let lookId = try stringArg(actions[0], "lookId")
		guard actions.allSatisfy({ ($0["pid"] as? NSNumber)?.int32Value == pid }) else {
			throw BridgeFailure(message: "actBatch actions must target one pid", code: "invalid_args")
		}
		guard actions.allSatisfy({ ($0["lookId"] as? String) == lookId }) else {
			throw BridgeFailure(message: "actBatch actions must belong to one look", code: "invalid_args")
		}
		let eventsLive = ensureRootObserver(pid: pid)
		let eventCursor = eventsLive ? rootEventCursor(pid: pid) : 0
		let beforeRootSnapshot = rootMetadataSnapshot(pid: pid)
		let beforeCgSignature = cgRootSignature(pid: pid)
		let beforeFrontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
		let mayUsePhysicalInput = actions.contains { action in
			(optionalStringArg(action, "policy") ?? "default") != "ax_only"
		}
		if mayUsePhysicalInput { physicalInputLock.lock() }
		defer { if mayUsePhysicalInput { physicalInputLock.unlock() } }

		var steps: [[String: Any]] = []
		var stoppedAt: Int?
		for (index, action) in actions.enumerated() {
			var deferred = action
			deferred["deferRootDelta"] = true
			do {
				let step = try act(deferred)
				steps.append(step)
				if (step["outcome"] as? String) == "didnt" { stoppedAt = index; break }
			} catch let failure as BridgeFailure {
				steps.append(["outcome": "didnt", "error": ["code": failure.code, "message": failure.message]])
				stoppedAt = index
				break
			}
		}
		let outcomes = steps.compactMap { $0["outcome"] as? String }
		let outcome = outcomes.contains("didnt") ? "didnt" : (outcomes.contains("unknown") ? "unknown" : "worked")
		var response: [String: Any] = ["outcome": outcome, "performed": ["transaction": true, "actionCount": steps.count], "steps": steps]
		if let stoppedAt { response["stoppedAt"] = stoppedAt }
		return attachRootDelta(to: response, before: beforeRootSnapshot, beforeFrontmostPid: beforeFrontmostPid, pid: pid, eventsLive: eventsLive, eventCursor: eventCursor, beforeCgSignature: beforeCgSignature)
	}
}
