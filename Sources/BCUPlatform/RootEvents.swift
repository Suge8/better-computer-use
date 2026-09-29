import AppKit

struct RootAXEvent {
	let sequence: UInt64
	let timestamp: TimeInterval
	let notification: String
	let element: AXUIElement?
}

final class RootAXObserverState {
	let pid: Int32
	let observer: AXObserver
	let change = NSCondition()
	var changeGeneration: UInt64 = 0
	var events: [RootAXEvent] = []
	var nextSequence: UInt64 = 1
	var lastUsed: TimeInterval = Date().timeIntervalSince1970

	init(pid: Int32, observer: AXObserver) {
		self.pid = pid
		self.observer = observer
	}
}

extension Platform {
	func ensureRootObserver(pid: Int32) -> Bool {
		rootObserverLock.lock()
		if let existing = rootObservers[pid] {
			existing.lastUsed = Date().timeIntervalSince1970
			rootObserverLock.unlock()
			return true
		}
		rootObserverLock.unlock()

		let appElement = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(appElement, 0.25)
		var observer: AXObserver?
		let createStatus = AXObserverCreate(pid, { observer, element, notification, refcon in
			guard let refcon else { return }
			let platform = Unmanaged<Platform>.fromOpaque(refcon).takeUnretainedValue()
			platform.recordRootAXEvent(observer: observer, notification: notification as String, element: element)
		}, &observer)
		guard createStatus == .success, let observer else { return false }

		let state = RootAXObserverState(pid: pid, observer: observer)
		let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
		let notifications: [CFString] = [
			"AXWindowCreated" as CFString,
			"AXSheetCreated" as CFString,
			"AXMenuOpened" as CFString,
			"AXMenuClosed" as CFString,
			"AXUIElementDestroyed" as CFString,
			"AXFocusedWindowChanged" as CFString,
			kAXValueChangedNotification as CFString,
			kAXTitleChangedNotification as CFString,
			kAXSelectedChildrenChangedNotification as CFString,
			kAXLayoutChangedNotification as CFString,
		]
		var registered = false
		let observedElements = [appElement] + axElementArray(appElement, attribute: kAXWindowsAttribute as CFString)
		for observed in observedElements {
			for notification in notifications {
				let status = AXObserverAddNotification(observer, observed, notification, context)
				if status == .success || status == .notificationAlreadyRegistered { registered = true }
			}
		}
		guard registered else { return false }

		rootObserverLock.lock()
		if rootObservers.count >= maxRootObservers,
			let evict = rootObservers.values.min(by: { $0.lastUsed < $1.lastUsed })?.pid
		{
			rootObservers.removeValue(forKey: evict)
		}
		rootObservers[pid] = state
		rootObserverLock.unlock()

		let source = AXObserverGetRunLoopSource(observer)
		Thread.detachNewThread {
			// Keep each AXObserver on its own run loop so its callbacks never compete
			// with AppKit rendering on the helper's main thread.
			CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
			CFRunLoopRun()
		}
		return true
	}

	func recordRootAXEvent(observer: AXObserver, notification: String, element: AXUIElement) {
		rootObserverLock.lock()
		let state = rootObservers.values.first { CFEqual($0.observer, observer) }
		if let state {
			state.events.append(RootAXEvent(sequence: state.nextSequence, timestamp: Date().timeIntervalSince1970, notification: notification, element: element))
			state.nextSequence += 1
			if state.events.count > 64 { state.events.removeFirst(state.events.count - 64) }
		}
		rootObserverLock.unlock()
		if let state {
			state.change.lock()
			state.changeGeneration += 1
			state.change.broadcast()
			state.change.unlock()
		}
	}

	func rootChangeGeneration(pid: Int32) -> UInt64 {
		rootObserverLock.lock()
		let state = rootObservers[pid]
		rootObserverLock.unlock()
		guard let state else { return 0 }
		state.change.lock()
		defer { state.change.unlock() }
		return state.changeGeneration
	}

	func waitForRootChange(pid: Int32, since generation: UInt64, until deadline: Date) {
		rootObserverLock.lock()
		let state = rootObservers[pid]
		rootObserverLock.unlock()
		guard let state else {
			Thread.sleep(forTimeInterval: min(0.2, max(0, deadline.timeIntervalSinceNow)))
			return
		}
		state.change.lock()
		if state.changeGeneration == generation {
			_ = state.change.wait(until: min(deadline, Date().addingTimeInterval(0.2)))
		}
		state.change.unlock()
	}

	func rootEventCursor(pid: Int32) -> UInt64 {
		rootObserverLock.lock()
		defer { rootObserverLock.unlock() }
		return rootObservers[pid]?.nextSequence ?? 1
	}

	func rootEvents(pid: Int32, since cursor: UInt64) -> [RootAXEvent] {
		rootObserverLock.lock()
		defer { rootObserverLock.unlock() }
		guard let events = rootObservers[pid]?.events else { return [] }
		return events.filter { $0.sequence >= cursor }
	}

	// Onscreen CGWindowList id set for one pid: ~1-2ms per call, so it can be
	// polled tightly where a full AX enumeration cannot.
	func cgRootSignature(pid: Int32) -> Set<UInt32> {
		guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
		var ids = Set<UInt32>()
		for entry in entries {
			guard let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner == pid else { continue }
			guard let windowId = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
			ids.insert(windowId)
		}
		return ids
	}
}
