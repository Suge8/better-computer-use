import AppKit

// The roots an action opened, closed or focused. They are evidence for an action that
// leaves no trace on its own element, and the caller's next targets.
extension Platform {
	func rootIdentity(_ root: Root) -> String {
		if let windowId = root.windowId, windowId > 0 { return "window:\(windowId)" }
		// AXUIElement CFEqual/CFHash are not stable after re-enumeration for all
		// transient roots; use the metadata tuple that comes from the cheap pass.
		let frame = root.framePoints
		return "meta:\(root.kind.rawValue):\(root.role):\(root.title):\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
	}

	func rootMetadataSnapshot(pid: Int32) -> [String: Root] {
		Dictionary(uniqueKeysWithValues: listRoots(pid: pid).map { (rootIdentity($0), $0) })
	}

	func rootDelta(before: [String: Root], beforeFrontmostPid: pid_t?, pid: Int32) -> [RootChange] {
		let after = rootMetadataSnapshot(pid: pid)
		var delta: [RootChange] = []
		for (key, root) in after where before[key] == nil {
			delta.append(.root(.appeared, root))
		}
		for (key, root) in before where after[key] == nil {
			delta.append(.root(.closed, root))
		}
		for (key, root) in after where root.isFocused && before[key]?.isFocused != true {
			delta.append(.root(.focused, root))
		}
		if let beforeFrontmostPid, beforeFrontmostPid != NSWorkspace.shared.frontmostApplication?.processIdentifier {
			if let frontmost = NSWorkspace.shared.frontmostApplication {
				delta.append(.frontApp(title: frontmost.localizedName ?? processName(pid: frontmost.processIdentifier) ?? "Unknown App", pid: frontmost.processIdentifier))
			}
		}
		return delta
	}

	/// How long an action's roots may take to change, and how long the accessibility tree may
	/// then lag the window server.
	static let rootChangeTimeout: TimeInterval = 0.4
	static let rootCatchUpTimeout: TimeInterval = 0.24

	/// The roots the action changed. The accessibility diff decides: macOS posts no
	/// notification at all when a sheet appears (verified on macOS 26), so notifications and
	/// the window server's list only say when to diff early. They are read again on every
	/// notification of the app and every change of front app; with no signal, the diff runs
	/// at the timeout.
	func awaitRootDelta(before: [String: Root], beforeFrontmostPid: pid_t?, pid: Int32, eventCursor: UInt64, beforeCgSignature: Set<UInt32>) throws -> (source: DeltaSource, delta: [RootChange]) {
		// AXUIElementDestroyed is not a signal: it fires for every rebuilt list row; a closed
		// root also leaves the window list.
		let signals: Set<String> = [kAXWindowCreatedNotification, kAXSheetCreatedNotification, kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXFocusedWindowChangedNotification]
		let notifications = try observedApp(pid)
		var source = DeltaSource.snapshot
		_ = try awaitChange(in: pid, timeout: Self.rootChangeTimeout) {
			if cgRootSignature(pid: pid) != beforeCgSignature { source = .windowList }
			else if let beforeFrontmostPid, NSWorkspace.shared.frontmostApplication?.processIdentifier != beforeFrontmostPid { source = .windowList }
			else if notifications.events(since: eventCursor).contains(where: { signals.contains($0.notification) }) { source = .events }
			return source != .snapshot
		}
		var delta = rootDelta(before: before, beforeFrontmostPid: beforeFrontmostPid, pid: pid)
		if delta.isEmpty && source != .snapshot {
			// A signal fired but the accessibility tree can lag the window server; it is
			// diffed again as the app announces changes.
			_ = try awaitChange(in: pid, timeout: Self.rootCatchUpTimeout) {
				delta = rootDelta(before: before, beforeFrontmostPid: beforeFrontmostPid, pid: pid)
				return !delta.isEmpty
			}
		}
		return (source, delta)
	}

	/// Some actions leave no trace on the element they target: pressing a menu item closes
	/// the menu. A root that appeared, closed or took focus inside the action's window is
	/// then the only evidence the action landed. Another app taking the front is not:
	/// activation hand-offs and the user do that on their own.
	func rootDeltaIsEvidence(_ delta: [RootChange], pid: Int32) -> Bool {
		delta.contains { change in
			if case .frontApp(_, let appPid) = change { return appPid == pid }
			return true
		}
	}
}
