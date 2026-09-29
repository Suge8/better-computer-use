import AppKit
import os

struct RootAXEvent: Sendable {
	let sequence: UInt64
	let notification: String
}

/// One app's accessibility notifications: its observer thread records them, requests read
/// them and wait for the next one.
final class AppNotifications: Sendable {
	private struct Log: Sendable {
		var events: [RootAXEvent] = []
		var nextSequence: UInt64 = 1
		var generation: UInt64 = 0
		var lastUsed = Date()
	}

	let pid: Int32
	private let log = OSAllocatedUnfairLock(initialState: Log())
	/// Waiters hold it while they compare generations, so a notification recorded between the
	/// comparison and the wait still wakes them.
	private let changed = NSCondition()

	init(pid: Int32) {
		self.pid = pid
	}

	var lastUsed: Date { log.withLock { $0.lastUsed } }
	var generation: UInt64 { log.withLock { $0.generation } }
	var cursor: UInt64 { log.withLock { $0.nextSequence } }

	func touch() {
		log.withLock { $0.lastUsed = Date() }
	}

	func record(_ notification: String) {
		log.withLock { log in
			log.events.append(RootAXEvent(sequence: log.nextSequence, notification: notification))
			log.nextSequence += 1
			if log.events.count > 64 { log.events.removeFirst(log.events.count - 64) }
			log.generation += 1
		}
		changed.lock()
		changed.broadcast()
		changed.unlock()
	}

	func events(since cursor: UInt64) -> [RootAXEvent] {
		log.withLock { $0.events.filter { $0.sequence >= cursor } }
	}

	/// Returns after the next notification, at the deadline, or after 0.2 s, whichever is first.
	func wait(since generation: UInt64, until deadline: Date) {
		changed.lock()
		if self.generation == generation {
			_ = changed.wait(until: min(deadline, Date().addingTimeInterval(0.2)))
		}
		changed.unlock()
	}
}

/// The apps whose notifications are observed; the least recently used is dropped past the limit.
final class RootObservers: Sendable {
	private static let limit = 4
	private let apps = OSAllocatedUnfairLock(initialState: [Int32: AppNotifications]())
	private let starting = NSLock()

	subscript(pid: Int32) -> AppNotifications? {
		apps.withLock { $0[pid] }
	}

	/// The app's notifications, starting an observer for it first when there is none; nil
	/// when the app accepts no observer. Starts are serialized, so an app never gets two.
	func ensure(_ pid: Int32, start: (AppNotifications) -> Bool) -> AppNotifications? {
		starting.withLock {
			if let existing = self[pid] {
				existing.touch()
				return existing
			}
			let app = AppNotifications(pid: pid)
			guard start(app) else { return nil }
			insert(app)
			return app
		}
	}

	private func insert(_ app: AppNotifications) {
		apps.withLock { apps in
			if apps.count >= Self.limit, let evict = apps.values.min(by: { $0.lastUsed < $1.lastUsed })?.pid {
				apps.removeValue(forKey: evict)
			}
			apps[app.pid] = app
		}
	}
}

private let observedNotifications = [
	"AXWindowCreated",
	"AXSheetCreated",
	"AXMenuOpened",
	"AXMenuClosed",
	"AXUIElementDestroyed",
	"AXFocusedWindowChanged",
	kAXValueChangedNotification,
	kAXTitleChangedNotification,
	kAXSelectedChildrenChangedNotification,
	kAXLayoutChangedNotification,
]

extension Platform {
	/// Starts observing the app's root changes unless it already is; false when the app
	/// accepts no observer.
	func ensureRootObserver(pid: Int32) -> Bool {
		rootObservers.ensure(pid, start: startObserver) != nil
	}

	/// Runs an observer for the app on a thread of its own; false when it could not register.
	private func startObserver(for app: AppNotifications) -> Bool {
		let started = DispatchSemaphore(value: 0)
		let observing = Box(false)
		// Each observer lives on its own thread and run loop, so its callbacks never compete
		// with AppKit rendering on the main thread. The thread keeps the observer and the log
		// its callbacks write to alive.
		Thread.detachNewThread { [self] in
			let observer = makeObserver(for: app)
			if let observer {
				CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
			}
			observing.value = observer != nil
			started.signal()
			guard observer != nil else { return }
			withExtendedLifetime((observer, app)) { CFRunLoopRun() }
		}
		started.wait()
		return observing.value
	}

	private func makeObserver(for app: AppNotifications) -> AXObserver? {
		let appElement = AXUIElementCreateApplication(app.pid)
		AXUIElementSetMessagingTimeout(appElement, 0.25)
		var observer: AXObserver?
		let createStatus = AXObserverCreate(app.pid, { _, _, notification, refcon in
			guard let refcon else { return }
			Unmanaged<AppNotifications>.fromOpaque(refcon).takeUnretainedValue().record(notification as String)
		}, &observer)
		guard createStatus == .success, let observer else { return nil }
		// Unretained: the observer thread holds `app` for as long as the observer can call back.
		let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(app).toOpaque())
		var registered = false
		for observed in [appElement] + axElementArray(appElement, attribute: kAXWindowsAttribute as CFString) {
			for notification in observedNotifications {
				let status = AXObserverAddNotification(observer, observed, notification as CFString, context)
				if status == .success || status == .notificationAlreadyRegistered { registered = true }
			}
		}
		return registered ? observer : nil
	}

	func rootChangeGeneration(pid: Int32) -> UInt64 {
		rootObservers[pid]?.generation ?? 0
	}

	func waitForRootChange(pid: Int32, since generation: UInt64, until deadline: Date) {
		guard let app = rootObservers[pid] else {
			Thread.sleep(forTimeInterval: min(0.2, max(0, deadline.timeIntervalSinceNow)))
			return
		}
		app.wait(since: generation, until: deadline)
	}

	func rootEventCursor(pid: Int32) -> UInt64 {
		rootObservers[pid]?.cursor ?? 1
	}

	func rootEvents(pid: Int32, since cursor: UInt64) -> [RootAXEvent] {
		rootObservers[pid]?.events(since: cursor) ?? []
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
