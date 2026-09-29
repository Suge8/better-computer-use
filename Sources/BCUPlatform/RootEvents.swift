import AppKit
import BCUCore
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

	/// Notifications kept for readers behind; one action reads back what it caused, which is
	/// far fewer.
	private static let retainedEvents = 64

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
			if log.events.count > Self.retainedEvents { log.events.removeFirst(log.events.count - Self.retainedEvents) }
			log.generation += 1
		}
		broadcast()
	}

	/// Wakes waiters without a notification of the app's own: another app took the front.
	func wake() {
		log.withLock { $0.generation += 1 }
		broadcast()
	}

	private func broadcast() {
		changed.lock()
		changed.broadcast()
		changed.unlock()
	}

	func events(since cursor: UInt64) -> [RootAXEvent] {
		log.withLock { $0.events.filter { $0.sequence >= cursor } }
	}

	/// Re-checks `condition` each time a notification arrives or the front app changes, until
	/// it holds or the deadline passes; whether it held. Between those events it sleeps.
	func wait(until deadline: Date, _ condition: () -> Bool) -> Bool {
		while true {
			let generation = self.generation
			if condition() { return true }
			if Date() >= deadline { return false }
			wait(since: generation, until: deadline)
		}
	}

	/// Returns after the next notification or wake, or at the deadline.
	private func wait(since generation: UInt64, until deadline: Date) {
		changed.lock()
		if self.generation == generation {
			_ = changed.wait(until: deadline)
		}
		changed.unlock()
	}
}

/// A thread that runs its own run loop until stopped, keeping alive what its setup returned.
final class RunLoopThread: Sendable {
	/// Sendable although `CFRunLoop` is not marked so: the only calls made on it from other
	/// threads are `CFRunLoopPerformBlock` and `CFRunLoopWakeUp`, which Core Foundation allows
	/// from any thread.
	private struct Loop: @unchecked Sendable {
		let runLoop: CFRunLoop
	}

	private let loop: Loop

	private init(_ loop: Loop) {
		self.loop = loop
	}

	/// Runs `setup` on a new thread; the thread keeps running its run loop only when setup
	/// returns something to keep, and nil is returned otherwise.
	static func start(_ setup: @escaping @Sendable () -> AnyObject?) -> RunLoopThread? {
		let started = DispatchSemaphore(value: 0)
		let loop = Handoff<Loop?>(nil)
		Thread.detachNewThread {
			let kept = setup()
			if kept != nil { loop.value = Loop(runLoop: CFRunLoopGetCurrent()) }
			started.signal()
			guard kept != nil else { return }
			withExtendedLifetime(kept) { CFRunLoopRun() }
		}
		started.wait()
		return loop.value.map(RunLoopThread.init)
	}

	/// Ends the run loop, and with it the thread and what it kept; a stop that arrives before
	/// the loop runs takes effect when it does.
	func stop() {
		CFRunLoopPerformBlock(loop.runLoop, CFRunLoopMode.commonModes.rawValue) {
			CFRunLoopStop(CFRunLoopGetCurrent())
		}
		CFRunLoopWakeUp(loop.runLoop)
	}
}

/// The apps whose notifications are observed. The least recently used is dropped past the
/// limit, and an app that quits is dropped; a dropped app's observer thread is stopped.
final class RootObservers: Sendable {
	private struct Observed: Sendable {
		let app: AppNotifications
		let thread: RunLoopThread
		let exit: any DispatchSourceProcess

		func stop() {
			exit.cancel()
			thread.stop()
		}
	}

	private static let limit = 4
	private let apps = OSAllocatedUnfairLock(initialState: [Int32: Observed]())
	private let starting = NSLock()

	/// Another app taking the front changes what every observed app's waiters look at: which
	/// app is frontmost, and a menu bar's geometry, which only the frontmost app has.
	init() {
		_ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] _ in
			self?.wakeAll()
		}
	}

	private func wakeAll() {
		for observed in apps.withLock({ Array($0.values) }) { observed.app.wake() }
	}

	subscript(pid: Int32) -> AppNotifications? {
		apps.withLock { $0[pid]?.app }
	}

	/// The app's notifications, starting an observer thread for it first when there is none;
	/// nil when the app accepts no observer. Starts are serialized, so an app never gets two.
	func ensure(_ pid: Int32, start: (AppNotifications) -> RunLoopThread?) -> AppNotifications? {
		starting.withLock {
			if let existing = self[pid] {
				existing.touch()
				return existing
			}
			let app = AppNotifications(pid: pid)
			guard let thread = start(app) else { return nil }
			let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
			exit.setEventHandler { [weak self] in self?.drop(app) }
			insert(Observed(app: app, thread: thread, exit: exit))
			exit.resume()
			return app
		}
	}

	private func insert(_ observed: Observed) {
		let evicted = apps.withLock { apps -> Observed? in
			var evicted: Observed?
			if apps.count >= Self.limit, let pid = apps.values.min(by: { $0.app.lastUsed < $1.app.lastUsed })?.app.pid {
				evicted = apps.removeValue(forKey: pid)
			}
			apps[observed.app.pid] = observed
			return evicted
		}
		evicted?.stop()
	}

	/// Drops the app if it is still the one observed under its pid; a pid reused by a later
	/// app keeps that app's observer.
	private func drop(_ app: AppNotifications) {
		let dropped = apps.withLock { apps -> Observed? in
			guard apps[app.pid]?.app === app else { return nil }
			return apps.removeValue(forKey: app.pid)
		}
		dropped?.stop()
	}
}

/// What an app announces that a waiter may be waiting for: roots coming and going, focus and
/// activation moving, values, titles, selection and text selection changing, and elements
/// being created or relaid out.
private let observedNotifications = [
	kAXWindowCreatedNotification,
	kAXSheetCreatedNotification,
	kAXMenuOpenedNotification,
	kAXMenuClosedNotification,
	kAXUIElementDestroyedNotification,
	kAXFocusedWindowChangedNotification,
	kAXMainWindowChangedNotification,
	kAXFocusedUIElementChangedNotification,
	kAXApplicationActivatedNotification,
	kAXApplicationDeactivatedNotification,
	kAXValueChangedNotification,
	kAXTitleChangedNotification,
	kAXSelectedChildrenChangedNotification,
	kAXSelectedRowsChangedNotification,
	kAXSelectedTextChangedNotification,
	kAXCreatedNotification,
	kAXLayoutChangedNotification,
]

extension Platform {
	/// The app's notifications, observing it first if it is not yet.
	func observedApp(_ pid: Int32) throws -> AppNotifications {
		guard let app = rootObservers.ensure(pid, start: startObserver) else {
			throw BCUError(.actionFailed, "The app accepts no accessibility observer, so bcu cannot wait for a change in it.")
		}
		return app
	}

	/// Re-checks `condition` whenever the app posts an accessibility notification or an app
	/// takes the front, until it holds or `timeout` passes; whether it held.
	func awaitChange(in pid: Int32, timeout: TimeInterval, _ condition: () -> Bool) throws -> Bool {
		try observedApp(pid).wait(until: Date().addingTimeInterval(timeout), condition)
	}

	/// Runs an observer for the app on a thread of its own; nil when it could not register.
	/// Its own run loop keeps its callbacks from competing with AppKit rendering on the main
	/// thread. The thread keeps the observer and, through this closure, the log its callbacks
	/// write to alive.
	private func startObserver(for app: AppNotifications) -> RunLoopThread? {
		RunLoopThread.start { [self] in
			guard let observer = makeObserver(for: app) else { return nil }
			CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
			return observer
		}
	}

	private func makeObserver(for app: AppNotifications) -> AXObserver? {
		let appElement = AXUIElementCreateApplication(app.pid)
		AXUIElementSetMessagingTimeout(appElement, quickMessagingTimeout)
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


	/// The pid's onscreen window ids: 1–2 ms to read, so it is re-read on every wake where a
	/// full accessibility enumeration is not.
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
