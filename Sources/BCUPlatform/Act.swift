import AppKit
import BCUCore

extension Platform {
	/// How long an action's effect may take to show: the element's own facts to move, a typed
	/// value to arrive.
	static let evidenceTimeout: TimeInterval = 0.25
	/// How long an activated app may take to own the front, or its menu bar its geometry.
	static let activationTimeout: TimeInterval = 0.5
	static let menuBarActivationTimeout: TimeInterval = 1.5
	/// How long a menu bcu presses open, or a pressed item's menus, may take to open or close.
	static let menuTimeout: TimeInterval = 1.0
	/// How long a background element may take to report that it holds the keyboard focus.
	static let focusReadbackTimeout: TimeInterval = 0.2
	/// How often the focus is asked for again while no notification says it moved.
	static let focusRetry: TimeInterval = 0.02
	/// Pause after raising a window before hit testing it again.
	static let raiseSettle: TimeInterval = 0.02
	/// How long, and how often, a scrolled element's content offset is read back.
	static let scrollTimeout: TimeInterval = 0.3
	static let scrollInterval: TimeInterval = 0.02

	/// Delivers one action on the look's root and judges its outcome from the evidence; see
	/// "投递梯子" and "Action transaction" in docs/architecture.md.
	public func act(_ request: ActRequest) throws -> ActionReport {
		try act(request, deferRootDelta: false)
	}

	/// `deferRootDelta` leaves the root changes to the batch that runs this step.
	func act(_ request: ActRequest, deferRootDelta: Bool) throws -> ActionReport {
		// What the app announces while bcu acts, and just after, may be the action's doing.
		try observedApp(request.pid).acting(lingering: Self.rootChangeTimeout) { try deliver(request, deferRootDelta: deferRootDelta) }
	}

	private func deliver(_ request: ActRequest, deferRootDelta: Bool) throws -> ActionReport {
		let record = request.geometry
		let pid = request.pid
		let action = request.action
		let params = request.params
		let policy = request.policy
		let delivery: Delivery = policy == .background || params.pidDelivery ? .pid : .hid
		var holdsPhysicalInput = false
		func acquirePhysicalInputIfNeeded() {
			if delivery == .hid && !holdsPhysicalInput {
				physicalInputLock.lock()
				holdsPhysicalInput = true
			}
		}
		defer { if holdsPhysicalInput { physicalInputLock.unlock() } }
		let pressLike = action == .press || action == .click
		// Typing an earlier step aimed: it goes to the focus as it is, with nothing focused first.
		let intoFocus = if case .focus = request.target { true } else { false }
		var performed = ActPerformed(delivery: delivery)
		var element: AXUIElement?
		var rawPoint: CGPoint?
		// The element the outcome is judged on, and whether the pointer provably reached it.
		var evidenceElement: AXUIElement?
		var beforeEvidence: [String: String]?
		var hitVerified = false
		var screenBefore: ScreenBaseline?
		let notifications = try observedApp(pid)
		var beforeFrontmostPid: pid_t?
		var eventCursor: UInt64 = 0
		var beforeRootSnapshot: [String: Root] = [:]
		var beforeCgSignature: Set<UInt32> = []
		var beforeSheetCount = 0
		var beforeFocusedWindow = ""
		/// The state the action's effect is measured against. Focusing the target for input is
		/// bcu's own doing, so it is taken into the baseline rather than counted as an effect.
		func takeRootBaseline() {
			beforeFrontmostPid = deferRootDelta ? nil : NSWorkspace.shared.frontmostApplication?.processIdentifier
			eventCursor = notifications.cursor
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
		/// Typing into a secure field: see `rootDeltaIsEvidence`.
		func typingIntoSecureField() -> Bool {
			[.typeText, .keypress].contains(action) && (element.map(isInSecureField) ?? false)
		}
		func finish(_ response: ActionReport) throws -> ActionReport {
			var result = response
			result.performed.typedIntoSecureField = typingIntoSecureField()
			if deferRootDelta { return result }
			let observed = try awaitRootDelta(before: beforeRootSnapshot, beforeFrontmostPid: beforeFrontmostPid, pid: pid, eventCursor: eventCursor, beforeCgSignature: beforeCgSignature, wait: !response.settled)
			result.performed.deltaSource = observed.source
			result.rootDelta = observed.delta
			if rootDeltaIsEvidence(observed.delta, pid: pid, typedIntoSecureField: result.performed.typedIntoSecureField), result.outcome == .unknown {
				result.outcome = .worked
				result.verification = ActEvidence(source: .root)
			}
			return result
		}
		/// Input posted to a pid reaches only its key window. The handoff is taken into the
		/// baseline, so it is never mistaken for the action's own effect.
		func focusTargetForBackgroundInput() throws {
			guard delivery == .pid, policy != .axOnly, !intoFocus,
				try focusWindowWithoutRaise(pid: pid, windowId: record.windowId)
			else { return }
			performed.focusedWindow = true
			takeBaseline()
		}

		switch request.target {
		case .element(let handle):
			var refound = false
			let cached = handle.elementRecord?.element.element
			let cachedIsLive = cached.map {
				stringAttribute($0, attribute: kAXRoleAttribute as CFString) != nil && frameForElement($0) != nil
			} ?? false
			var resolved: AXUIElement?
			if cachedIsLive {
				resolved = cached
			} else {
				resolved = handle.elementRecord.flatMap { refindElement($0.snapshot, pid: pid, windowId: record.windowId) }
				refound = resolved != nil
				// Geometry is missing for whole families of live elements — the menu bar of a
				// background app draws nothing — so an element that still answers accessibility
				// is the target even when nothing can be refound for it.
				if resolved == nil, let cached, stringAttribute(cached, attribute: kAXRoleAttribute as CFString) != nil { resolved = cached }
			}
			guard let stored = resolved else {
				throw BCUError(.elementNotFound, "Element reference is stale")
			}
			if refound { performed.refound = true }
			element = stored
			evidenceElement = stored
			beforeEvidence = evidenceSnapshot(stored)
		case .focus:
			break
		case .point(let x, let y):
			let point = lookPoint(record, x: x, y: y)
			rawPoint = point
			// A plain click over a native discrete control takes the same ladder as its ref,
			// starting from a background AXPress. Web content keeps the pointer: Chromium's own
			// pointer path is exact, and its AXPress cannot be told apart from a no-op.
			let plainClick = pressLike && params.button == .left && params.clickCount == 1
			if plainClick, let control = coordinateSubject(at: point, pid: pid, windowId: record.windowId),
				Self.discreteControlRoles.contains(stringAttribute(control, attribute: kAXRoleAttribute as CFString) ?? ""),
				supportsAction(control, action: kAXPressAction as CFString),
				!hasAncestorRole(control, role: "AXWebArea")
			{
				element = control
				evidenceElement = control
				beforeEvidence = evidenceSnapshot(control)
			}
		}

		// Read once: grounding and the cursor's target box share it, so the cursor costs no extra AX query.
		var readFrame: CGRect??
		func elementFrame() -> CGRect? {
			if let readFrame { return readFrame }
			let frame = element.flatMap(frameForElement)
			readFrame = .some(frame)
			return frame
		}

		func coordinatePoint() throws -> CGPoint {
			if let rawPoint { return rawPoint }
			if let frame = elementFrame() {
				return CGPoint(x: frame.midX, y: frame.midY)
			}
			throw BCUError(.actionFailed, "No coordinate grounding is available")
		}

		func animateCursor(at point: CGPoint) {
			guard let motion = agentCursor,
				request.cursorOverlay,
				delivery == .pid,
				policy != .axOnly,
				[.press, .click, .moveMouse, .scroll, .drag].contains(action)
			else { return }
			// The overlay joins every Space; over a window in another Space it would draw on the user's.
			if SpaceView()?.placement(of: record.windowId) == .elsewhere { return }
			let target = elementFrame()
			Task { @MainActor in AgentCursor.shared.animate(to: point, above: record.windowId, motion: motion, action: action, target: target) }
		}

		/// Activation is asynchronous: a menu bar item has no geometry until it belongs to the
		/// frontmost app, and that geometry is the signal to wait for. An item inside a closed
		/// menu has none either way, so the menu bar item above it is watched instead. The
		/// switch is bcu's own doing, so the baseline is taken after it.
		func activateForMenuBar(_ item: AXUIElement) throws {
			guard let app = NSRunningApplication(processIdentifier: pid) else { return }
			performed.activated = app.activate()
			let barItem = ancestor(of: item, role: kAXMenuBarItemRole as String) ?? item
			_ = try awaitChange(in: pid, timeout: Self.menuBarActivationTimeout) { (frameForElement(barItem)?.width ?? 0) > 0 }
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
				let cursor = notifications.cursor
				guard AXUIElementPerformAction(opener, kAXPressAction as CFString) == .success else {
					throw BCUError(.actionFailed, "The menu holding '\(title)' did not open")
				}
				// AppKit posts AXMenuOpened once the menu is validated and tracking; the menu's
				// geometry can appear before that, so the notification is what is waited for.
				let isOpen = try awaitChange(in: pid, timeout: Self.menuTimeout) {
					notifications.events(since: cursor).contains { $0.notification == kAXMenuOpenedNotification }
				}
				guard isOpen else { throw BCUError(.actionFailed, "The menu holding '\(title)' did not open") }
			}
			eventCursor = notifications.cursor
			if opened != nil { performed.openedMenus = true }
			if boolAttribute(item, attribute: kAXEnabledAttribute as CFString) == false {
				_ = AXUIElementPerformAction(item, kAXCancelAction as CFString)
				throw BCUError(.actionFailed, "The menu item '\(title)' is disabled")
			}
			return opened
		}

		/// A pressed menu item closes its menus a moment later; the roots are judged once the
		/// menus bcu opened are gone, so they are neither an appeared nor a closed root.
		func awaitMenuClosed(_ shown: AXUIElement) throws {
			_ = try awaitChange(in: pid, timeout: Self.menuTimeout) { (frameForElement(shown)?.width ?? 0) <= 0 }
		}

		/// Keys go to whatever the app has focused, so the element is focused first. In the
		/// background nothing else puts the focus there: the keys are sent only once the app reads
		/// back that the element, or something inside it, holds the focus (ported from trycua/cua).
		func focusForKeys(_ target: AXUIElement) throws {
			func focus() {
				if AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success { performed.focused = true }
			}
			guard delivery == .pid else { return focus() }
			// A busy app can drop the request, so it is made again on every look, as cua does.
			let deadline = Date().addingTimeInterval(Self.focusReadbackTimeout)
			while true {
				let generation = notifications.generation
				focus()
				if holdsKeyboardFocus(target, pid: pid) { return }
				let now = Date()
				guard now < deadline else { break }
				notifications.wait(since: generation, until: min(deadline, now.addingTimeInterval(Self.focusRetry)))
			}
			throw ForegroundRequired(message: "The element did not take the keyboard focus in the background, so keys sent there could land elsewhere")
		}

		func focusTargetForPhysicalInput() throws {
			guard delivery == .hid else { return }
			if let app = NSRunningApplication(processIdentifier: pid), !app.isActive {
				performed.activated = app.activate()
			}
			if let window = resolveRoot(pid: pid, windowId: record.windowId) {
				_ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
				_ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
				performed.raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
			}
			// Activation lands asynchronously; the baseline waits for it so the switch is
			// never read as the action's effect.
			_ = try awaitChange(in: pid, timeout: Self.activationTimeout) { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
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
				if delivery == .hid && attempt < 3 {
					try focusTargetForPhysicalInput()
					// Raising reorders windows, which no accessibility notification reports.
					Thread.sleep(forTimeInterval: Self.raiseSettle)
					continue
				}
				let label = stringAttribute(hit, attribute: kAXTitleAttribute as CFString) ?? ""
				throw BCUError(.actionFailed, "Target is occluded by \(role.isEmpty ? "an element" : role)\(label.isEmpty ? "" : " '\(label)'")")
			}
		}

		func executeCoordinates(_ point: CGPoint) throws {
			if delivery == .pid, Tk.isMapped(pid: pid) {
				throw ForegroundRequired(message: "Tk drops pointer events sent to a background app, so this needs the real pointer")
			}
			performed.grounding = .coordinates
			if delivery == .pid { performed.callerMustVerify = true }
			let subject = element ?? coordinateSubject(at: point, pid: pid, windowId: record.windowId)
			let webTarget = subject.map { hasAncestorRole($0, role: "AXWebArea") } ?? false
			let readable = subject.map(hasReadableEvidence) ?? false
			// Screen evidence is reserved for a point whose resolved subject has no AX fact
			// that a press, a wheel turn or a drag would move; see docs/architecture.md.
			let screenTarget = (pressLike || action == .scroll || action == .drag) && !webTarget && !readable
			if element == nil, pressLike, readable, let subject {
				evidenceElement = subject
				beforeEvidence = evidenceSnapshot(subject)
				hitVerified = true
			}
			acquirePhysicalInputIfNeeded()
			if delivery == .pid, !webTarget {
				// A stock NSView drops the first click on an inactive app; this makes the
				// target app take the click without becoming the front app.
				try SkyLight.activateWithoutRaise(windowId: record.windowId)
				performed.backgroundActivation = true
			} else {
				try focusTargetForPhysicalInput()
				try focusTargetForBackgroundInput()
			}
			if screenTarget { screenBefore = screenBaseline(windowId: record.windowId) }
			if delivery == .hid { try preflight(point) }
			let route = SkyLight.PointerRoute(pid: pid, windowId: record.windowId, windowOrigin: record.windowFrame.origin)
			switch action {
			case .press, .click:
				animateCursor(at: point)
				try postMouseClick(at: point, pid: pid, route: route, button: params.button, clickCount: max(1, min(3, params.clickCount)), delivery: delivery)
			case .moveMouse:
				animateCursor(at: point)
				try postMouseMove(to: point, pid: pid, delivery: delivery)
			case .scroll:
				animateCursor(at: point)
				try postScrollWheel(at: point, deltaX: params.scrollX, deltaY: params.scrollY, pid: pid, route: route, delivery: delivery)
			case .drag:
				guard let path = params.path, path.count >= 2 else {
					throw BCUError(.invalidArguments, "drag requires path")
				}
				animateCursor(at: point)
				try postMouseDrag(points: path.map { lookPoint(record, x: $0.x, y: $0.y) }, pid: pid, route: route, delivery: delivery)
			case .setText, .typeText, .keypress:
				throw BCUError(.invalidArguments, "Action \(action.rawValue) cannot use coordinate grounding")
			}
		}

		func refreshElement() -> AXUIElement? {
			guard case .element(let handle) = request.target,
				let snapshot = handle.elementRecord?.snapshot,
				let refreshed = refindElement(snapshot, pid: pid, windowId: record.windowId)
			else { return nil }
			element = refreshed
			performed.refound = true
			return refreshed
		}

		/// Judges the outcome on the evidence rules; see docs/architecture.md. Every effect the
		/// delivery may have is awaited in one window: the subject's facts, an announcement of
		/// the window, a root signal. The first ends it, and the roots are then diffed without
		/// waiting again.
		func verdict() throws -> ActionReport {
			let deliveredAt = Date()
			let root = resolveRoot(pid: pid, windowId: record.windowId)
			let subject = element ?? evidenceElement
			var after = subject.flatMap(evidenceSnapshot)
			var announced: ActEvidence?
			var unread = eventCursor
			_ = notifications.wait(until: deliveredAt.addingTimeInterval(Self.rootChangeTimeout)) {
				if let subject, let before = beforeEvidence {
					after = evidenceSnapshot(subject)
					guard let after else { return true }
					if evidenceDifference(before: before, after: after) != nil { return true }
				}
				// Each notification is looked at once, however many the app posts while it settles.
				let next = notifications.cursor
				announced = root.flatMap { announcement(notifications, since: unread, in: $0, deliveredAt: deliveredAt) }
				unread = next
				// A batch takes no root baseline per step; it diffs the roots once, after the last.
				return announced != nil || (!deferRootDelta && rootSignal(notifications, eventCursor: eventCursor, beforeCgSignature: beforeCgSignature, beforeFrontmostPid: beforeFrontmostPid) != nil)
			}
			performed.effectsAwaited = true
			let afterSheetCount = root.map { sheetElements(of: $0).count } ?? beforeSheetCount
			let windowChanged = !typingIntoSecureField() && (beforeFocusedWindow != focusedWindowSummary(pid: pid) || beforeSheetCount != afterSheetCount)
			var outcome = ActOutcome.unknown
			var verification: ActEvidence?
			// The element that was acted on speaks first: its own value, selection or focus
			// moving is proof no window-level summary can contradict.
			if let subject, let before = beforeEvidence {
				if let after, let difference = evidenceDifference(before: before, after: after) {
					outcome = .worked
					verification = difference
				} else if pressLike, hitVerified, after?["focused"] == "1", !Set([kAXWindowRole, kAXApplicationRole]).contains(stringAttribute(subject, attribute: kAXRoleAttribute as CFString) ?? "") {
					// The pointer provably reached this element and it now holds keyboard focus:
					// a click that only places a caret leaves no other trace.
					outcome = .worked
					verification = ActEvidence(source: .focus, field: .focused)
				} else if pressLike, after?["value"] == "1", isAlreadySelected(subject, before: before) {
					// A click that landed on a selected tab or segment: it is where it was asked to be.
					outcome = .worked
					verification = ActEvidence(source: .ax, field: .alreadySelected)
				} else if pressLike, after != nil, before["value"] != nil, pressEffect(subject) != nil {
					outcome = .didnt
					verification = ActEvidence(source: .ax, field: .value, from: evidenceExcerpt(before["value"] ?? ""), to: evidenceExcerpt(before["value"] ?? ""))
				}
			}
			if outcome == .unknown, windowChanged {
				outcome = .worked
				verification = ActEvidence(source: .root)
			}
			if outcome == .unknown, let announced {
				outcome = .worked
				verification = announced
			}
			// Weakest evidence, and the slowest to read: only for a subject with no AX fact.
			if outcome == .unknown, let screenBefore, screenChanged(since: screenBefore, deliveredAt: deliveredAt) {
				outcome = .worked
				verification = ActEvidence(source: .screen, field: .changed)
			}
			return ActionReport(outcome: outcome, performed: performed, verification: verification)
		}

		// Pressing a selected radio, tab or segment asks for what already holds. It is not
		// delivered: a segmented control sends its action again on such a click (a re-sort, a
		// reload), and an agent selecting it wants none of that.
		if let element, pressLike, isAlreadySelected(element, before: beforeEvidence) {
			performed.grounding = .description
			performed.delivery = .ax
			return try finish(ActionReport(outcome: .worked, performed: performed, verification: ActEvidence(source: .ax, field: .alreadySelected)))
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
			if requiresFrontmost && policy != .foreground {
				throw ForegroundRequired(message: "The menu bar only answers in the frontmost app")
			}
			if requiresPointerFocus && policy != .axOnly {
				if policy == .foreground {
					try executeCoordinates(coordinatePoint())
				} else {
					throw ForegroundRequired(message: "Text input needs the real pointer to place its caret")
				}
			} else if supportsAction(element, action: kAXPressAction as CFString) {
				if requiresFrontmost { try activateForMenuBar(element) }
				let openedMenu = inMenuBar && elementRole == kAXMenuItemRole as String ? try openMenusAbove(element) : nil
				let cursorPoint = try? coordinatePoint()
				// Pixels are the evidence of last resort, and capturing them before the press costs
				// as much as the press itself: only a window Accessibility cannot describe needs them.
				if record.readScreen, !inWebContent, !hasReadableEvidence(element) { screenBefore = screenBaseline(windowId: record.windowId) }
				var status = AXUIElementPerformAction(element, kAXPressAction as CFString)
				if status == .invalidUIElement, let refreshed = refreshElement(), supportsAction(refreshed, action: kAXPressAction as CFString) {
					status = AXUIElementPerformAction(refreshed, kAXPressAction as CFString)
				}
				// An error is not a non-delivery: a press that blocks its app until the message
				// times out (a button running a modal dialog) is still being handled, and
				// pressing or clicking again would run it twice. Only an error that proves the
				// request never arrived leaves the press undone; any other is judged on the
				// evidence, like a press that succeeded.
				if !Self.actionNeverArrived(status) {
					performed.grounding = .description
					performed.delivery = .ax
					if let openedMenu { try awaitMenuClosed(openedMenu) }
					if let cursorPoint { animateCursor(at: cursorPoint) }
					// The ladder rule of docs/architecture.md: only a press that provably changed
					// nothing (`didnt`) moves on to raw input. An unknown one stays put: Chromium's
					// AXPress already dispatches mousedown, mouseup and click, so pressing again
					// would apply the action twice.
					let axVerdict = try verdict()
					if policy == .axOnly || axVerdict.outcome != .didnt { return try finish(axVerdict) }
					performed.delivery = delivery
					try executeCoordinates(coordinatePoint())
				} else {
					try executeCoordinates(coordinatePoint())
				}
			} else {
				try executeCoordinates(coordinatePoint())
			}
		} else if let element, action == .setText {
			let text = params.text
			if let route = finderRenameRoute(for: element, pid: pid) {
				throw BCUError(.actionFailed, "Writing a Finder file name changes what Finder shows, not the file's name.", recovery: route)
			}
			var targetElement = element
			var status = AXUIElementSetAttributeValue(targetElement, kAXValueAttribute as CFString, text as CFTypeRef)
			if status != .success, let refreshed = refreshElement() {
				targetElement = refreshed
				status = AXUIElementSetAttributeValue(targetElement, kAXValueAttribute as CFString, text as CFTypeRef)
			}
			if status == .success {
				performed.grounding = .description
				performed.delivery = .ax
				let value = stringAttribute(targetElement, attribute: kAXValueAttribute as CFString) ?? ""
				if value != text && policy != .foreground {
					throw ForegroundRequired(message: "The background accessibility value write was accepted but did not take effect")
				}
				return try finish(ActionReport(
					outcome: value == text ? .worked : .didnt,
					performed: performed,
					verification: ActEvidence(source: .ax, field: .value, from: evidenceExcerpt(beforeEvidence?["value"] ?? ""), to: evidenceExcerpt(value))
				))
			}
			try executeCoordinates(coordinatePoint())
		} else if action == .typeText {
			try focusTargetForBackgroundInput()
			if let element { try focusForKeys(element) }
			acquirePhysicalInputIfNeeded()
			if delivery == .hid && !intoFocus { try focusTargetForPhysicalInput() }
			let text = params.text
			try postUnicodeText(text, pid: pid, delivery: delivery)
			performed.grounding = .coordinates
			if let element, !text.isEmpty {
				let judged = try judgeTyped(text, in: element, pid: pid, valueBefore: beforeEvidence?["value"])
				return try finish(ActionReport(outcome: judged.outcome, performed: performed, verification: judged.evidence))
			}
		} else if action == .keypress {
			let keys = params.keys
			guard !keys.isEmpty else {
				throw BCUError(.invalidArguments, "keypress requires keys")
			}
			try focusTargetForBackgroundInput()
			if let element {
				try focusForKeys(element)
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
						performed.selectedAllViaAX = true
					}
				}
			}
			acquirePhysicalInputIfNeeded()
			if delivery == .hid && !intoFocus { try focusTargetForPhysicalInput() }
			try postKeyPress(keys: keys, pid: pid, delivery: delivery)
			performed.grounding = .coordinates
		} else if let element, action == .scroll {
			let cursorPoint = try? coordinatePoint()
			let before = scrollPositionSignature(element)
			// Chromium exposes no scroll action on a scrollable element, and the actions of
			// its ancestors scroll the page instead, so web content scrolls by a wheel turn
			// over the element itself.
			let scrollsByWheel = hasAncestorRole(element, role: "AXWebArea") && !supportsAnyScrollAction(element)
			if !scrollsByWheel, performScrollActionOrAncestor(startingAt: element, targetPid: pid, scrollX: params.scrollX, scrollY: params.scrollY) {
				performed.grounding = .description
				performed.delivery = .ax
				if let cursorPoint { animateCursor(at: cursorPoint) }
			} else {
				try executeCoordinates(coordinatePoint())
			}
			// Web content reports the new offset a frame or two after the wheel turn. Chromium
			// announces no scroll in Accessibility, so the offset is read again on an interval.
			let deadline = Date().addingTimeInterval(Self.scrollTimeout)
			while before == scrollPositionSignature(element) {
				guard Date() < deadline else { return try finish(ActionReport(outcome: .unknown, performed: performed)) }
				Thread.sleep(forTimeInterval: Self.scrollInterval)
			}
			return try finish(ActionReport(outcome: .worked, performed: performed, verification: ActEvidence(source: .ax, field: .scroll)))
		} else {
			try executeCoordinates(coordinatePoint())
		}

		return try finish(try verdict())
	}

	/// The element says it is focused, or the app's focused element is it or inside it.
	func holdsKeyboardFocus(_ element: AXUIElement, pid: Int32) -> Bool {
		if boolAttribute(element, attribute: kAXFocusedAttribute as CFString) == true { return true }
		let app = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(app, messagingTimeout)
		guard let focused = copyAttribute(app, attribute: kAXFocusedUIElementAttribute as CFString).flatMap(asAXElement) else { return false }
		return isElement(focused, descendantOf: element)
	}

	/// Delivers up to 20 actions on one look as a transaction: one resource lock, one root
	/// baseline, and a stop at the first step that provably did nothing or failed.
	public func actBatch(_ requests: [ActRequest]) throws -> BatchReport {
		guard let first = requests.first, requests.count <= 20 else {
			throw BCUError(.invalidArguments, "A batch needs 1 to 20 actions")
		}
		let pid = first.pid
		guard requests.allSatisfy({ $0.pid == pid }) else {
			throw BCUError(.invalidArguments, "Batched actions must target one app")
		}
		let eventCursor = try observedApp(pid).cursor
		let beforeRootSnapshot = rootMetadataSnapshot(pid: pid)
		let beforeCgSignature = cgRootSignature(pid: pid)
		let beforeFrontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
		let mayUsePhysicalInput = requests.contains { $0.policy != .axOnly }
		if mayUsePhysicalInput { physicalInputLock.lock() }
		defer { if mayUsePhysicalInput { physicalInputLock.unlock() } }

		var steps: [ActStep] = []
		var stoppedAt: Int?
		for (index, request) in requests.enumerated() {
			do {
				let step = try act(request, deferRootDelta: true)
				steps.append(.completed(step))
				if step.outcome == .didnt { stoppedAt = index; break }
			} catch let failure as BCUError {
				steps.append(.failed(failure))
				stoppedAt = index
				break
			} catch let refusal as ForegroundRequired {
				steps.append(.failed(BCUError(.actionFailed, refusal.message)))
				stoppedAt = index
				break
			}
		}
		let outcomes = steps.map(\.outcome)
		let settled = steps.allSatisfy { if case .completed(let report) = $0 { report.settled } else { true } }
		let observed = try awaitRootDelta(before: beforeRootSnapshot, beforeFrontmostPid: beforeFrontmostPid, pid: pid, eventCursor: eventCursor, beforeCgSignature: beforeCgSignature, wait: !settled)
		var result = BatchReport(
			outcome: outcomes.contains(.didnt) ? .didnt : (outcomes.contains(.unknown) ? .unknown : .worked),
			steps: steps,
			stoppedAt: stoppedAt,
			deltaSource: observed.source,
			verification: nil,
			rootDelta: observed.delta
		)
		let typedIntoSecureField = steps.contains { if case .completed(let report) = $0 { report.performed.typedIntoSecureField } else { false } }
		if rootDeltaIsEvidence(observed.delta, pid: pid, typedIntoSecureField: typedIntoSecureField), result.outcome == .unknown {
			result.outcome = .worked
			result.verification = ActEvidence(source: .root)
		}
		return result
	}
}
