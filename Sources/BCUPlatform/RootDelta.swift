import AppKit

extension Bridge {
	func rootIdentity(_ root: [String: Any]) -> String {
		if let windowId = root["windowId"] as? Int, windowId > 0 { return "window:\(windowId)" }
		// AXUIElement CFEqual/CFHash are not stable after re-enumeration for all
		// transient roots; use the metadata tuple that comes from the cheap pass.
		let kind = root["kind"] as? String ?? "window"
		let title = root["title"] as? String ?? ""
		let role = root["role"] as? String ?? ""
		let frame = root["framePoints"] as? [String: Any] ?? [:]
		let x = Int((frame["x"] as? NSNumber)?.doubleValue ?? 0)
		let y = Int((frame["y"] as? NSNumber)?.doubleValue ?? 0)
		let w = Int((frame["w"] as? NSNumber)?.doubleValue ?? 0)
		let h = Int((frame["h"] as? NSNumber)?.doubleValue ?? 0)
		return "meta:\(kind):\(role):\(title):\(x),\(y),\(w),\(h)"
	}

	func rootMetadataSnapshot(pid: Int32) -> [String: [String: Any]] {
		let roots = ((try? listRoots(pid: pid)["roots"] as? [[String: Any]]) ?? [])
		return Dictionary(uniqueKeysWithValues: roots.map { (rootIdentity($0), $0) })
	}

	func rootDelta(before: [String: [String: Any]], beforeFrontmostPid: pid_t?, pid: Int32) -> [[String: Any]] {
		let after = rootMetadataSnapshot(pid: pid)
		var delta: [[String: Any]] = []
		for (key, root) in after where before[key] == nil {
			delta.append(rootDeltaItem(change: "appeared", root: root, pid: pid))
		}
		for (key, root) in before where after[key] == nil {
			delta.append(rootDeltaItem(change: "closed", root: root, pid: pid))
		}
		for (key, root) in after {
			if (root["isFocused"] as? Bool) == true && (before[key]?["isFocused"] as? Bool) != true {
				delta.append(rootDeltaItem(change: "focused", root: root, pid: pid))
			}
		}
		if let beforeFrontmostPid, beforeFrontmostPid != NSWorkspace.shared.frontmostApplication?.processIdentifier {
			if let frontmost = NSWorkspace.shared.frontmostApplication {
				delta.append(["change": "focused", "kind": "app", "title": frontmost.localizedName ?? processName(pid: frontmost.processIdentifier) ?? "Unknown App", "pid": Int(frontmost.processIdentifier)])
			}
		}
		return delta
	}

	/// A changed root is reported in the same shape discovery uses, so a caller can observe
	/// it straight away instead of listing roots again and racing the change.
	func rootDeltaItem(change: String, root: [String: Any], pid: Int32) -> [String: Any] {
		var item = root
		item["change"] = change
		item["pid"] = root["pid"] as? Int ?? Int(pid)
		return item
	}

	// The AX snapshot diff is authoritative: macOS emits no AXObserver
	// notification at all when a sheet appears (verified on macOS 26), so
	// events can only accelerate the decision, never make it. A cheap
	// CGWindowList id-set poll detects real-window appearance/closure early;
	// the AX diff runs once at the first signal or at timeout.
	func attachRootDelta(to response: [String: Any], before: [String: [String: Any]], beforeFrontmostPid: pid_t?, pid: Int32, eventsLive: Bool, eventCursor: UInt64, beforeCgSignature: Set<UInt32>) -> [String: Any] {
		var output = response
		var performed = output["performed"] as? [String: Any] ?? [:]

		// AXUIElementDestroyed is deliberately not a signal: it fires for every
		// rebuilt list row; a genuinely closed root also leaves the CG set.
		let signalNotifications: Set<String> = ["AXWindowCreated", "AXSheetCreated", "AXMenuOpened", "AXMenuClosed", "AXFocusedWindowChanged"]
		var source = "snapshot"
		let deadline = Date().addingTimeInterval(0.40)
		while Date() < deadline {
			if cgRootSignature(pid: pid) != beforeCgSignature { source = "cg-poll"; break }
			if let beforeFrontmostPid, NSWorkspace.shared.frontmostApplication?.processIdentifier != beforeFrontmostPid { source = "cg-poll"; break }
			if eventsLive && rootEvents(pid: pid, since: eventCursor).contains(where: { signalNotifications.contains($0.notification) }) { source = "events"; break }
			usleep(30_000)
		}

		var delta = rootDelta(before: before, beforeFrontmostPid: beforeFrontmostPid, pid: pid)
		if delta.isEmpty && source != "snapshot" {
			// A signal fired but the AX tree can lag the CG window; give it a
			// bounded moment to catch up.
			for _ in 0..<3 where delta.isEmpty {
				usleep(80_000)
				delta = rootDelta(before: before, beforeFrontmostPid: beforeFrontmostPid, pid: pid)
			}
		}
		performed["deltaSource"] = source
		output["performed"] = performed
		if !delta.isEmpty { output["rootDelta"] = delta }
		// Some actions leave no trace on the element they target: pressing a menu item
		// closes the menu. A root that appeared, closed or took focus inside the action's
		// window is then the only evidence the action landed. Another app taking the front
		// is not: activation hand-offs and the user do that on their own.
		let evidential = delta.filter { !(($0["change"] as? String) == "focused" && ($0["kind"] as? String) == "app" && ($0["pid"] as? Int) != Int(pid)) }
		if !evidential.isEmpty, (output["outcome"] as? String) == "unknown" {
			output["outcome"] = "worked"
			output["verification"] = ["source": "root"]
		}
		return output
	}
}
