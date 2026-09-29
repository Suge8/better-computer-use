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

	// The AX snapshot diff is authoritative: macOS emits no AXObserver
	// notification at all when a sheet appears (verified on macOS 26), so
	// events can only accelerate the decision, never make it. A cheap
	// CGWindowList id-set poll detects real-window appearance/closure early;
	// the AX diff runs once at the first signal or at timeout.
	func awaitRootDelta(before: [String: Root], beforeFrontmostPid: pid_t?, pid: Int32, eventsLive: Bool, eventCursor: UInt64, beforeCgSignature: Set<UInt32>) -> (source: DeltaSource, delta: [RootChange]) {
		// AXUIElementDestroyed is deliberately not a signal: it fires for every
		// rebuilt list row; a genuinely closed root also leaves the CG set.
		let signalNotifications: Set<String> = ["AXWindowCreated", "AXSheetCreated", "AXMenuOpened", "AXMenuClosed", "AXFocusedWindowChanged"]
		var source = DeltaSource.snapshot
		let deadline = Date().addingTimeInterval(0.40)
		while Date() < deadline {
			if cgRootSignature(pid: pid) != beforeCgSignature { source = .cgPoll; break }
			if let beforeFrontmostPid, NSWorkspace.shared.frontmostApplication?.processIdentifier != beforeFrontmostPid { source = .cgPoll; break }
			if eventsLive && rootEvents(pid: pid, since: eventCursor).contains(where: { signalNotifications.contains($0.notification) }) { source = .events; break }
			usleep(30_000)
		}

		var delta = rootDelta(before: before, beforeFrontmostPid: beforeFrontmostPid, pid: pid)
		if delta.isEmpty && source != .snapshot {
			// A signal fired but the AX tree can lag the CG window; give it a
			// bounded moment to catch up.
			for _ in 0..<3 where delta.isEmpty {
				usleep(80_000)
				delta = rootDelta(before: before, beforeFrontmostPid: beforeFrontmostPid, pid: pid)
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
