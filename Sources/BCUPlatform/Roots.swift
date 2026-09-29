import AppKit

extension Platform {
	public func listApps() -> [RunningApp] {
		listApps(cgEntries: nil)
	}

	func listApps(cgEntries: [[String: Any]]?) -> [RunningApp] {
		let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
		let apps = NSWorkspace.shared.runningApplications.filter { app in
			// Computer-use targets are windows, not Dock-visible applications. Some
			// benchmark/test apps and utility-style apps expose perfectly valid AX
			// windows while using an accessory/prohibited activation policy, so do not
			// gate discovery on `.regular` here. `listWindows` and the higher-level
			// window collector filter to actual controllable windows.
			app.processIdentifier != getpid() && pidIsAlive(app.processIdentifier)
		}
		var seen = Set<Int32>()
		var output = apps.map { app in
			seen.insert(app.processIdentifier)
			return RunningApp(
				appName: app.localizedName ?? processName(pid: app.processIdentifier) ?? "Unknown App",
				pid: app.processIdentifier,
				bundleId: app.bundleIdentifier,
				isFrontmost: app.processIdentifier == frontmostPid
			)
		}

		// NSWorkspace can miss apps launched from ad-hoc bundles or test harnesses
		// even when their windows are visible and AX-controllable. Add CGWindow
		// owners as acquisition candidates so callers can still resolve by pid/title
		// and then build the normal AX scene through listWindows(pid:).
		for owner in cgWindowOwners(entries: cgEntries) where owner.pid != getpid() && !seen.contains(owner.pid) && pidIsAlive(owner.pid) {
			seen.insert(owner.pid)
			output.append(RunningApp(appName: owner.name, pid: owner.pid, bundleId: nil, isFrontmost: owner.pid == frontmostPid))
		}
		return output
	}

	public func frontmost() throws -> Frontmost {
		guard let app = NSWorkspace.shared.frontmostApplication else {
			throw PlatformError(message: "No frontmost app available", code: "frontmost_unavailable")
		}
		let pid = app.processIdentifier
		let appName = app.localizedName ?? "Unknown App"
		let windows = listWindows(pid: pid, appName: appName, bundleId: app.bundleIdentifier)
		return Frontmost(appName: appName, pid: pid, bundleId: app.bundleIdentifier, window: windows.sorted { windowScore($0) > windowScore($1) }.first)
	}

	func windowScore(_ window: Root) -> Int {
		var score = 0
		if window.isFocused { score += 100 }
		if window.isMain { score += 80 }
		if !window.isMinimized { score += 40 }
		if window.isOnscreen { score += 20 }
		if window.windowId != nil { score += 10 }
		return score
	}

	public func focusWindow(_ target: RootTarget) -> FocusWindowResult {
		guard let window = resolveRoot(pid: target.pid, windowId: target.windowId, rootRef: target.rootRef) else {
			return FocusWindowResult(focused: false, alreadyFocused: false, setMain: nil, setFocused: nil, raised: nil, reason: "window_not_found")
		}

		let appElement = AXUIElementCreateApplication(target.pid)
		if let focusedWindow = copyAttribute(appElement, attribute: kAXFocusedWindowAttribute as CFString).flatMap(asAXElement),
			sameElement(focusedWindow, window)
		{
			return FocusWindowResult(focused: true, alreadyFocused: true, setMain: nil, setFocused: nil, raised: nil, reason: nil)
		}

		let setMain = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue) == .success
		let setFocused = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
		let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
		let focused = setMain || setFocused || raised
		return FocusWindowResult(focused: focused, alreadyFocused: false, setMain: setMain, setFocused: setFocused, raised: raised, reason: focused ? nil : "focus_failed")
	}

	/// A popup menu that Accessibility never exposed as an element is still a real root on
	/// screen; its Quartz window id is the only identity it has.
	func cgMenuWindowId(_ rootRef: String) -> UInt32? {
		guard rootRef.hasPrefix(cgMenuRefPrefix) else { return nil }
		return UInt32(rootRef.dropFirst(cgMenuRefPrefix.count))
	}

	func rootKind(role: String, subrole: String) -> RootKind {
		if role == "AXMenuBar" { return .menubar }
		if role == "AXMenu" { return .menu }
		if role == "AXSheet" { return .sheet }
		if subrole.localizedCaseInsensitiveContains("popover") { return .popover }
		if subrole.localizedCaseInsensitiveContains("dialog") || role == "AXDialog" { return .dialog }
		return .window
	}

	func isDialogLikeRoot(role: String, subrole: String) -> Bool {
		let text = "\(role) \(subrole)"
		return text.range(of: "dialog", options: [.caseInsensitive]) != nil
			|| text.range(of: "modal", options: [.caseInsensitive]) != nil
			|| text.range(of: "sheet", options: [.caseInsensitive]) != nil
	}

	func rootMetadata(pairing: WindowPairing, sheetCount: Int) -> RootMetadata {
		RootMetadata(pairing: RootPairing(confidence: pairing.confidence, score: pairing.score), sheetCount: sheetCount)
	}

	/// An app's menu bar is a root in its own right: it is how every app command is reached,
	/// and it exists whether or not the app owns a window on screen.
	func menuBarRoot(pid: Int32, appName: String, bundleId: String?) -> Root? {
		let appElement = AXUIElementCreateApplication(pid)
		guard let bar = copyAttribute(appElement, attribute: kAXMenuBarAttribute as CFString).flatMap(asAXElement) else { return nil }
		let frame = frameForWindow(bar)
		guard frame.width > 1, frame.height > 1 else { return nil }
		return Root(
			kind: .menubar,
			rootRef: refStore.storeWindow(bar),
			windowId: nil,
			// Behind every window, and never the root an unqualified query should land on.
			zOrder: Int.max,
			// A menu bar has no title of its own, and discovery may know the app only by its
			// executable name; the localized app name is the one identity that always matches.
			title: NSRunningApplication(processIdentifier: pid)?.localizedName ?? appName,
			role: "AXMenuBar",
			subrole: "",
			isModal: false,
			framePoints: frame,
			scaleFactor: displayScaleFactor(for: frame),
			isMinimized: false,
			isOnscreen: true,
			isMain: false,
			isFocused: false,
			metadata: nil,
			pid: pid,
			appName: appName,
			bundleId: bundleId
		)
	}

	/// The apps a root search covers; `appName` is nil when only the pid is known.
	private struct RootOwner {
		let pid: Int32
		let appName: String?
		let bundleId: String?
	}

	private func broadRootOwners(entries: [[String: Any]]) -> [RootOwner] {
		cgBroadRootOwners(entries: entries).compactMap { owner in
			guard owner.pid != getpid(), pidIsAlive(owner.pid) else { return nil }
			return RootOwner(pid: owner.pid, appName: owner.name, bundleId: NSRunningApplication(processIdentifier: owner.pid)?.bundleIdentifier)
		}
	}

	/// Every root of one app (`pid`), of the apps with a window whose title contains `title`,
	/// or, with neither, of every app that shows a window or an open menu; front to back.
	public func listRoots(pid: Int32? = nil, title: String? = nil) -> [Root] {
		let requestedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
		let entries = allCGWindowEntries()
		let isBroadDiscovery = pid == nil && requestedTitle.isEmpty
		let owners: [RootOwner]
		if let pid {
			owners = [RootOwner(pid: pid, appName: nil, bundleId: nil)]
		} else if !requestedTitle.isEmpty {
			let matchingPids = Set(entries.compactMap { entry -> Int32? in
				let candidate = ((entry[kCGWindowName as String] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
				guard candidate == requestedTitle || candidate.contains(requestedTitle) else { return nil }
				return (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
			})
			owners = listApps(cgEntries: entries).filter { matchingPids.contains($0.pid) }.map { RootOwner(pid: $0.pid, appName: $0.appName, bundleId: $0.bundleId) }
		} else {
			owners = broadRootOwners(entries: entries)
		}
		var roots: [Root] = []
		for owner in owners {
			let appPid = owner.pid
			let appName = owner.appName ?? processName(pid: appPid) ?? "Unknown App"
			let bundleId = owner.bundleId
			roots += listWindows(pid: appPid, appName: appName, bundleId: bundleId, cgEntries: entries, messagingTimeout: isBroadDiscovery ? 0.25 : 1.0)
			let popupCandidates = cgPopupMenuCandidates(pid: appPid, entries: entries)
			let menuElements = popupCandidates.isEmpty ? [] : openMenuElements(pid: appPid, messagingTimeout: isBroadDiscovery ? 0.25 : 1.0)
			for candidate in popupCandidates {
				let menuElement = menuElement(drawnBy: candidate, among: menuElements)
				roots.append(Root(
					kind: .menu,
					rootRef: menuElement.map { refStore.storeWindow($0) } ?? "\(cgMenuRefPrefix)\(candidate.windowId)",
					windowId: candidate.windowId,
					zOrder: candidate.zOrder,
					title: menuElement.flatMap { menuTitle($0) } ?? candidate.title,
					role: "AXMenu",
					subrole: "",
					isModal: false,
					framePoints: candidate.bounds,
					scaleFactor: displayScaleFactor(for: candidate.bounds),
					isMinimized: false,
					isOnscreen: candidate.isOnscreen,
					isMain: false,
					isFocused: true,
					metadata: RootMetadata(pairing: RootPairing(confidence: menuElement == nil ? .low : .high, score: menuElement == nil ? 0 : 100), sheetCount: 0),
					pid: appPid,
					appName: appName,
					bundleId: bundleId
				))
			}
			if let bar = menuBarRoot(pid: appPid, appName: appName, bundleId: bundleId) { roots.append(bar) }
		}
		roots.sort { $0.zOrder < $1.zOrder }
		return roots
	}

	/// The app's windows and their sheets, in the app's own window order.
	func listWindows(pid: Int32, appName: String, bundleId: String?, cgEntries: [[String: Any]]? = nil, messagingTimeout: Float = 1.0) -> [Root] {
		ensureEnhancedAccessibility(pid: pid)
		let appElement = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
		let windows = Array(axElementArray(appElement, attribute: kAXWindowsAttribute as CFString).prefix(128))
		let candidates = cgWindowCandidates(pid: pid, entries: cgEntries)
		let pairings = windowPairings(windows: windows, candidates: candidates)

		var output: [Root] = []
		for (zIndex, window) in windows.enumerated() {
			let axTitle = stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? ""
			let axRole = stringAttribute(window, attribute: kAXRoleAttribute as CFString) ?? ""
			let axSubrole = stringAttribute(window, attribute: kAXSubroleAttribute as CFString) ?? ""
			let axFrame = frameForWindow(window)
			let pairing = pairings[ObjectIdentifier(window)] ?? .unpaired
			let candidate = pairing.candidate

			let effectiveFrame = axFrame.width > 1 && axFrame.height > 1 ? axFrame : (candidate?.bounds ?? axFrame)
			if effectiveFrame.width < 100 || effectiveFrame.height < 80 { continue }
			let hasUsableAXFrame = axFrame.width > 1 && axFrame.height > 1
			let title = hasUsableAXFrame && !axTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? axTitle : (candidate?.title.isEmpty == false ? candidate!.title : axTitle)
			let rootRef = refStore.storeWindow(window)
			let isMinimized = boolAttribute(window, attribute: kAXMinimizedAttribute as CFString) ?? false
			let isMain = boolAttribute(window, attribute: kAXMainAttribute as CFString) ?? false
			let isFocused = boolAttribute(window, attribute: kAXFocusedAttribute as CFString) ?? false
			let sheetCount = sheetElements(of: window).count
			let isModal = (boolAttribute(window, attribute: "AXModal" as CFString) ?? false) || sheetCount > 0 || isDialogLikeRoot(role: axRole, subrole: axSubrole)

			output.append(Root(
				kind: rootKind(role: axRole, subrole: axSubrole),
				rootRef: rootRef,
				windowId: candidate?.windowId,
				zOrder: candidate?.zOrder ?? zIndex,
				title: title,
				role: axRole,
				subrole: axSubrole,
				isModal: isModal,
				framePoints: effectiveFrame,
				scaleFactor: displayScaleFactor(for: effectiveFrame),
				isMinimized: isMinimized,
				isOnscreen: candidate?.isOnscreen ?? !isMinimized,
				isMain: isMain,
				isFocused: isFocused,
				metadata: rootMetadata(pairing: pairing, sheetCount: sheetCount),
				pid: pid,
				appName: appName,
				bundleId: bundleId
			))

			for sheet in sheetElements(of: window) {
				let sheetRef = refStore.storeWindow(sheet)
				let sheetFrame = frameForWindow(sheet)
				let sheetCandidate = bestCandidate(for: sheet, candidates: candidates)
				output.append(Root(
					kind: .sheet,
					rootRef: sheetRef,
					windowId: sheetCandidate?.windowId,
					zOrder: sheetCandidate?.zOrder ?? candidate?.zOrder ?? zIndex,
					title: stringAttribute(sheet, attribute: kAXTitleAttribute as CFString) ?? title,
					role: stringAttribute(sheet, attribute: kAXRoleAttribute as CFString) ?? "AXSheet",
					subrole: stringAttribute(sheet, attribute: kAXSubroleAttribute as CFString) ?? "",
					isModal: true,
					framePoints: sheetFrame,
					scaleFactor: displayScaleFactor(for: sheetFrame),
					isMinimized: false,
					isOnscreen: sheetCandidate?.isOnscreen ?? candidate?.isOnscreen ?? !isMinimized,
					isMain: false,
					isFocused: isFocused,
					metadata: RootMetadata(pairing: sheetCandidate == nil ? RootPairing(confidence: pairing.confidence, score: pairing.score) : RootPairing(confidence: .high, score: 100), sheetCount: 0),
					pid: pid,
					appName: appName,
					bundleId: bundleId
				))
			}
		}
		return output
	}

	/// A supplied root ref is authoritative: menus, sheets and popovers have no window id,
	/// so a ref that no longer resolves must fail instead of silently selecting another root.
	func resolveRoot(pid: Int32, windowId: UInt32?, rootRef: String? = nil) -> AXUIElement? {
		if let rootRef {
			guard let stored = refStore.window(for: rootRef) else { return nil }
			AXUIElementSetMessagingTimeout(stored, 1.0)
			var ownerPid: pid_t = 0
			guard AXUIElementGetPid(stored, &ownerPid) == .success, ownerPid == pid else { return nil }
			return stored
		}

		let appElement = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(appElement, 1.0)
		let windows = Array(axElementArray(appElement, attribute: kAXWindowsAttribute as CFString).prefix(128))
		guard !windows.isEmpty else { return nil }
		guard let windowId else {
			return windows.first
		}
		let candidates = cgWindowCandidates(pid: pid)
		let pairings = windowPairings(windows: windows, candidates: candidates)
		for window in windows {
			if pairings[ObjectIdentifier(window)]?.candidate?.windowId == windowId {
				return window
			}
			for sheet in sheetElements(of: window) {
				if bestCandidate(for: sheet, candidates: candidates)?.windowId == windowId {
					return sheet
				}
			}
		}
		return nil
	}

	/// AXMenu elements exist for every closed submenu too; only an open menu reports a frame,
	/// so the frame is what separates the menu the user sees from the rest of the menu tree.
	func isOpenMenu(_ element: AXUIElement) -> Bool {
		let frame = frameForWindow(element)
		return frame.width > 1 && frame.height > 1
	}

	/// The open menu a popup window draws. The window is the menu plus its shadow margin
	/// (75 pt on every side on macOS 27), so it is paired by containment and centre rather
	/// than by equal geometry.
	func menuElement(drawnBy candidate: CGWindowCandidate, among menus: [AXUIElement]) -> AXUIElement? {
		let centre = CGPoint(x: candidate.bounds.midX, y: candidate.bounds.midY)
		return menus
			.map { (menu: $0, frame: frameForWindow($0)) }
			.filter { candidate.bounds.contains($0.frame) }
			.min { hypot($0.frame.midX - centre.x, $0.frame.midY - centre.y) < hypot($1.frame.midX - centre.x, $1.frame.midY - centre.y) }?
			.menu
	}

	/// An AXMenu carries no title of its own; the menu bar item that owns it does.
	func menuTitle(_ menu: AXUIElement) -> String? {
		if let own = stringAttribute(menu, attribute: kAXTitleAttribute as CFString), !own.isEmpty { return own }
		guard let parent = parentElement(menu) else { return nil }
		guard let title = stringAttribute(parent, attribute: kAXTitleAttribute as CFString), !title.isEmpty else { return nil }
		return title
	}

	func openMenuElements(pid: Int32, messagingTimeout: Float = 1.0) -> [AXUIElement] {
		let app = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(app, messagingTimeout)
		let descendants = collectDescendants(startingAt: app, maxDepth: 6)
		var menus = descendants.filter { (stringAttribute($0, attribute: kAXRoleAttribute as CFString) ?? "") == "AXMenu" && isOpenMenu($0) }
		if menus.isEmpty,
			let focused = copyAttribute(app, attribute: kAXFocusedUIElementAttribute as CFString).flatMap(asAXElement)
		{
			var current: AXUIElement? = focused
			while let element = current {
				if (stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? "") == "AXMenu" {
					menus.append(element)
					break
				}
				current = copyAttribute(element, attribute: kAXParentAttribute as CFString).flatMap(asAXElement)
			}
		}
		return menus
	}
}
