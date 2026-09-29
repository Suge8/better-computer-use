import AppKit

extension Bridge {
	func listApps(cgEntries: [[String: Any]]? = nil) -> [[String: Any]] {
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
			var data: [String: Any] = [
				"appName": app.localizedName ?? processName(pid: app.processIdentifier) ?? "Unknown App",
				"pid": Int(app.processIdentifier),
				"isFrontmost": app.processIdentifier == frontmostPid,
			]
			if let bundleId = app.bundleIdentifier {
				data["bundleId"] = bundleId
			}
			return data
		}

		// NSWorkspace can miss apps launched from ad-hoc bundles or test harnesses
		// even when their windows are visible and AX-controllable. Add CGWindow
		// owners as acquisition candidates so callers can still resolve by pid/title
		// and then build the normal AX scene through listWindows(pid:).
		for owner in cgWindowOwners(entries: cgEntries) where owner.pid != getpid() && !seen.contains(owner.pid) && pidIsAlive(owner.pid) {
			seen.insert(owner.pid)
			output.append([
				"appName": owner.name,
				"pid": Int(owner.pid),
				"isFrontmost": owner.pid == frontmostPid,
			])
		}
		return output
	}

	func getFrontmost() throws -> [String: Any] {
		guard let app = NSWorkspace.shared.frontmostApplication else {
			throw BridgeFailure(message: "No frontmost app available", code: "frontmost_unavailable")
		}
		let pid = app.processIdentifier
		let windows = try listWindows(pid: pid)

		var result: [String: Any] = [
			"appName": app.localizedName ?? "Unknown App",
			"pid": Int(pid),
		]
		if let bundleId = app.bundleIdentifier {
			result["bundleId"] = bundleId
		}

		if let chosen = windows.sorted(by: { scoreWindow($0) > scoreWindow($1) }).first {
			result["windowTitle"] = (chosen["title"] as? String) ?? ""
			if let windowId = chosen["windowId"] {
				result["windowId"] = windowId
			}
			if let rootRef = chosen["rootRef"] as? String {
				result["rootRef"] = rootRef
			}
		}
		return result
	}

	func scoreWindow(_ window: [String: Any]) -> Int {
		var score = 0
		if (window["isFocused"] as? Bool) == true { score += 100 }
		if (window["isMain"] as? Bool) == true { score += 80 }
		if (window["isMinimized"] as? Bool) == false { score += 40 }
		if (window["isOnscreen"] as? Bool) == true { score += 20 }
		if window["windowId"] != nil { score += 10 }
		return score
	}

	/// A popup menu that Accessibility never exposed as an element is still a real root on
	/// screen; its Quartz window id is the only identity it has.
	func cgMenuWindowId(_ rootRef: String) -> UInt32? {
		guard rootRef.hasPrefix(cgMenuRefPrefix) else { return nil }
		return UInt32(rootRef.dropFirst(cgMenuRefPrefix.count))
	}

	func rootKind(role: String, subrole: String) -> String {
		if role == "AXMenuBar" { return "menubar" }
		if role == "AXMenu" { return "menu" }
		if role == "AXSheet" { return "sheet" }
		if subrole.localizedCaseInsensitiveContains("popover") { return "popover" }
		if subrole.localizedCaseInsensitiveContains("dialog") || role == "AXDialog" { return "dialog" }
		return "window"
	}

	func isDialogLikeRoot(role: String, subrole: String) -> Bool {
		let text = "\(role) \(subrole)"
		return text.range(of: "dialog", options: [.caseInsensitive]) != nil
			|| text.range(of: "modal", options: [.caseInsensitive]) != nil
			|| text.range(of: "sheet", options: [.caseInsensitive]) != nil
	}

	func rootMetadata(pairing: WindowPairing, sheetCount: Int) -> [String: Any] {
		["pairing": ["confidence": pairing.confidence, "score": pairing.score], "sheetCount": sheetCount]
	}

	/// An app's menu bar is a root in its own right: it is how every app command is reached,
	/// and it exists whether or not the app owns a window on screen.
	func menuBarRoot(pid: Int32, appName: String, bundleId: String?) -> [String: Any]? {
		let appElement = AXUIElementCreateApplication(pid)
		guard let bar = copyAttribute(appElement, attribute: kAXMenuBarAttribute as CFString).flatMap(asAXElement) else { return nil }
		let frame = frameForWindow(bar)
		guard frame.width > 1, frame.height > 1 else { return nil }
		// A menu bar has no title of its own, and discovery may know the app only by its
		// executable name; the localized app name is the one identity that always matches.
		let title = NSRunningApplication(processIdentifier: pid)?.localizedName ?? appName
		var root: [String: Any] = [
			"kind": "menubar",
			"rootRef": refStore.storeWindow(bar),
			// Behind every window, and never the root an unqualified query should land on.
			"zOrder": Int.max,
			"title": title,
			"role": "AXMenuBar",
			"subrole": "",
			"isModal": false,
			"framePoints": ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height],
			"scaleFactor": displayScaleFactor(for: frame),
			"isMinimized": false,
			"isOnscreen": true,
			"isMain": false,
			"isFocused": false,
			"pid": Int(pid),
			"appName": appName,
		]
		if let bundleId { root["bundleId"] = bundleId }
		return root
	}

	func broadRootCandidateApps(entries: [[String: Any]]) -> [[String: Any]] {
		cgBroadRootOwners(entries: entries).compactMap { owner in
			guard owner.pid != getpid(), pidIsAlive(owner.pid) else { return nil }
			var app: [String: Any] = ["appName": owner.name, "pid": Int(owner.pid)]
			if let bundleId = NSRunningApplication(processIdentifier: owner.pid)?.bundleIdentifier {
				app["bundleId"] = bundleId
			}
			return app
		}
	}

	func listRoots(pid: Int32?, title: String? = nil) throws -> [String: Any] {
		let requestedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
		let entries = allCGWindowEntries()
		let isBroadDiscovery = pid == nil && requestedTitle.isEmpty
		let apps: [[String: Any]]
		if let pid {
			apps = [["pid": Int(pid)]]
		} else if !requestedTitle.isEmpty {
			let matchingPids = Set(entries.compactMap { entry -> Int32? in
				let candidate = ((entry[kCGWindowName as String] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
				guard candidate == requestedTitle || candidate.contains(requestedTitle) else { return nil }
				return (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
			})
			apps = listApps(cgEntries: entries).filter { app in
				guard let rawPid = app["pid"] as? Int else { return false }
				return matchingPids.contains(Int32(rawPid))
			}
		} else {
			apps = broadRootCandidateApps(entries: entries)
		}
		var roots: [[String: Any]] = []
		for app in apps {
			guard let rawPid = app["pid"] as? Int else { continue }
			let appPid = Int32(rawPid)
			let appName = app["appName"] as? String ?? processName(pid: appPid) ?? "Unknown App"
			let bundleId = app["bundleId"] as? String
			for var root in (try? listWindows(pid: appPid, cgEntries: entries, messagingTimeout: isBroadDiscovery ? 0.25 : 1.0)) ?? [] {
				root["pid"] = rawPid
				root["appName"] = appName
				if let bundleId { root["bundleId"] = bundleId }
				roots.append(root)
			}
			let popupCandidates = cgPopupMenuCandidates(pid: appPid, entries: entries)
			let menuElements = popupCandidates.isEmpty ? [] : openMenuElements(pid: appPid, messagingTimeout: isBroadDiscovery ? 0.25 : 1.0)
			for candidate in popupCandidates {
				let menuElement = menuElement(drawnBy: candidate, among: menuElements)
				let menuRef = menuElement.map { refStore.storeWindow($0) } ?? "\(cgMenuRefPrefix)\(candidate.windowId)"
				var menu: [String: Any] = [
					"kind": "menu",
					"rootRef": menuRef,
					"windowId": Int(candidate.windowId),
					"zOrder": candidate.zOrder,
					"title": menuElement.flatMap { menuTitle($0) } ?? candidate.title,
					"role": "AXMenu",
					"subrole": "",
					"isModal": false,
					"framePoints": ["x": candidate.bounds.origin.x, "y": candidate.bounds.origin.y, "w": candidate.bounds.width, "h": candidate.bounds.height],
					"scaleFactor": displayScaleFactor(for: candidate.bounds),
					"isMinimized": false,
					"isOnscreen": candidate.isOnscreen,
					"isMain": false,
					"isFocused": true,
					"metadata": ["pairing": ["confidence": menuElement == nil ? "low" : "high", "score": menuElement == nil ? 0 : 100], "sheetCount": 0],
					"pid": rawPid,
					"appName": appName,
				]
				if let bundleId { menu["bundleId"] = bundleId }
				roots.append(menu)
			}
			if let bar = menuBarRoot(pid: appPid, appName: appName, bundleId: bundleId) { roots.append(bar) }
		}
		roots.sort { (($0["zOrder"] as? Int) ?? Int.max) < (($1["zOrder"] as? Int) ?? Int.max) }
		return ["roots": roots]
	}

	func listWindows(pid: Int32, cgEntries: [[String: Any]]? = nil, messagingTimeout: Float = 1.0) throws -> [[String: Any]] {
		ensureEnhancedAccessibility(pid: pid)
		let appElement = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
		let windows = Array(axElementArray(appElement, attribute: kAXWindowsAttribute as CFString).prefix(128))
		let candidates = cgWindowCandidates(pid: pid, entries: cgEntries)
		let pairings = windowPairings(windows: windows, candidates: candidates)

		var output: [[String: Any]] = []
		for (zIndex, window) in windows.enumerated() {
			let axTitle = stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? ""
			let axRole = stringAttribute(window, attribute: kAXRoleAttribute as CFString) ?? ""
			let axSubrole = stringAttribute(window, attribute: kAXSubroleAttribute as CFString) ?? ""
			let axFrame = frameForWindow(window)
			let pairing = pairings[ObjectIdentifier(window)] ?? WindowPairing(candidate: nil, score: -Double.greatestFiniteMagnitude, confidence: "low")
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
			let scale = displayScaleFactor(for: effectiveFrame)

			var item: [String: Any] = [
				"kind": rootKind(role: axRole, subrole: axSubrole),
				"rootRef": rootRef,
				"zOrder": candidate?.zOrder ?? zIndex,
				"title": title,
				"role": axRole,
				"subrole": axSubrole,
				"isModal": isModal,
				"framePoints": [
					"x": effectiveFrame.origin.x,
					"y": effectiveFrame.origin.y,
					"w": effectiveFrame.size.width,
					"h": effectiveFrame.size.height,
				],
				"scaleFactor": scale,
				"isMinimized": isMinimized,
				"isOnscreen": candidate?.isOnscreen ?? !isMinimized,
				"isMain": isMain,
				"isFocused": isFocused,
				"metadata": rootMetadata(pairing: pairing, sheetCount: sheetCount),
			]
			if let candidate {
				item["windowId"] = Int(candidate.windowId)
			}
			output.append(item)

			for sheet in sheetElements(of: window) {
				let sheetRef = refStore.storeWindow(sheet)
				let sheetFrame = frameForWindow(sheet)
				let sheetCandidate = bestCandidate(for: sheet, candidates: candidates)
				var sheetItem: [String: Any] = [
					"kind": "sheet",
					"rootRef": sheetRef,
					"zOrder": sheetCandidate?.zOrder ?? candidate?.zOrder ?? zIndex,
					"title": stringAttribute(sheet, attribute: kAXTitleAttribute as CFString) ?? title,
					"role": stringAttribute(sheet, attribute: kAXRoleAttribute as CFString) ?? "AXSheet",
					"subrole": stringAttribute(sheet, attribute: kAXSubroleAttribute as CFString) ?? "",
					"isModal": true,
					"framePoints": ["x": sheetFrame.origin.x, "y": sheetFrame.origin.y, "w": sheetFrame.width, "h": sheetFrame.height],
					"scaleFactor": displayScaleFactor(for: sheetFrame),
					"isMinimized": false,
					"isOnscreen": sheetCandidate?.isOnscreen ?? candidate?.isOnscreen ?? !isMinimized,
					"isMain": false,
					"isFocused": isFocused,
					"metadata": ["pairing": ["confidence": sheetCandidate == nil ? pairing.confidence : "high", "score": sheetCandidate == nil ? pairing.score : 100], "sheetCount": 0],
				]
				if let sheetCandidate { sheetItem["windowId"] = Int(sheetCandidate.windowId) }
				output.append(sheetItem)
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
