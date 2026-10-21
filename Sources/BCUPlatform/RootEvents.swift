import AppKit
import BCUCore
import os

struct RootAXEvent: Sendable {
	let sequence: UInt64
	let notification: String
	/// The element whose value or title changed; kept only for those two notifications.
	let element: AXElement?
	let at: Date
}

/// A count of changes that waiters compare and sleep on: whoever records a change bumps it,
/// and every waiter re-checks its condition.
final class ChangeSignal: Sendable {
	private let count = OSAllocatedUnfairLock(initialState: UInt64(0))
	/// Waiters hold it while they compare generations, so a change recorded between the
	/// comparison and the wait still wakes them.
	private let changed = NSCondition()

	var generation: UInt64 { count.withLock { $0 } }

	func bump() {
		count.withLock { $0 += 1 }
		changed.lock()
		changed.broadcast()
		changed.unlock()
	}

	/// Re-checks `condition` after each change, until it holds or the deadline passes; whether
	/// it held. Between changes it sleeps.
	func wait(until deadline: Date, _ condition: () -> Bool) -> Bool {
		while true {
			let generation = self.generation
			if condition() { return true }
			if Date() >= deadline { return false }
			wait(since: generation, until: deadline)
		}
	}

	/// Returns after the next change since `generation`, or at the deadline.
	func wait(since generation: UInt64, until deadline: Date) {
		changed.lock()
		if self.generation == generation {
			_ = changed.wait(until: deadline)
		}
		changed.unlock()
	}
}

/// One app's accessibility notifications: its observer thread records them, requests read
/// them and wait for the next one. Each one also counts as a change of the whole desktop.
final class AppNotifications: Sendable {
	private struct Log: Sendable {
		var events: [RootAXEvent] = []
		/// Actions of bcu on the app in progress, and until when the last one's effects may
		/// still be arriving.
		var acting = 0
		var actedUntil = Date.distantPast
		/// When each element last announced a change of its own (see `selfChangeLookback`).
		var changedOnItsOwn: [AXElement: Date] = [:]
		var nextSequence: UInt64 = 1
		var lastUsed = Date()
	}

	/// Notifications kept for readers behind: what one action caused, and what the app
	/// announced on its own in the seconds before it (a busy window posts dozens a second).
	private static let retainedEvents = 256

	/// How far back an element counts as changing on its own: a clock ticks once a second, a
	/// progress bar or timer faster, so two seconds see each of them at least once. An element
	/// quieter than that (a chat that gets a message now and then) can still coincide with a
	/// delivery. History starts when bcu starts observing the app, at its first look.
	static let selfChangeLookback: TimeInterval = 2

	let pid: Int32
	private let log = OSAllocatedUnfairLock(initialState: Log())
	private let signal = ChangeSignal()
	private let desktop: ChangeSignal

	init(pid: Int32, desktop: ChangeSignal) {
		self.pid = pid
		self.desktop = desktop
	}

	var lastUsed: Date { log.withLock { $0.lastUsed } }
	var generation: UInt64 { signal.generation }
	var cursor: UInt64 { log.withLock { $0.nextSequence } }

	func touch() {
		log.withLock { $0.lastUsed = Date() }
	}

	/// A change announced while bcu acts may be the action's; it counts as the element's own
	/// only when the element was already changing on its own, so an element that keeps
	/// changing stays known through any run of actions, and one that changes only when acted
	/// on (a calculator's display) never becomes so.
	func record(_ notification: String, element: AXElement? = nil) {
		let now = Date()
		log.withLock { log in
			if let element {
				let known = log.changedOnItsOwn[element].map { now.timeIntervalSince($0) <= Self.selfChangeLookback } ?? false
				if (log.acting == 0 && now > log.actedUntil) || known { log.changedOnItsOwn[element] = now }
				log.changedOnItsOwn = log.changedOnItsOwn.filter { now.timeIntervalSince($0.value) <= Self.selfChangeLookback }
			}
			log.events.append(RootAXEvent(sequence: log.nextSequence, notification: notification, element: element, at: now))
			log.nextSequence += 1
			if log.events.count > Self.retainedEvents { log.events.removeFirst(log.events.count - Self.retainedEvents) }
		}
		signal.bump()
		desktop.bump()
	}

	/// Wakes waiters without a notification of the app's own: another app took the front.
	func wake() {
		signal.bump()
	}

	func events(since cursor: UInt64) -> [RootAXEvent] {
		log.withLock { $0.events.filter { $0.sequence >= cursor } }
	}

	/// Whether the element announced a change of its own within the lookback before `date`.
	func changesOnItsOwn(_ element: AXElement, before date: Date) -> Bool {
		log.withLock { log in log.changedOnItsOwn[element].map { date.timeIntervalSince($0) <= Self.selfChangeLookback } ?? false }
	}

	/// Runs `body` as an action of bcu on the app, whose effects may keep arriving for
	/// `lingering` after it: see `record`.
	func acting<T>(lingering: TimeInterval, _ body: () throws -> T) rethrows -> T {
		log.withLock { $0.acting += 1 }
		defer {
			log.withLock { log in
				log.acting -= 1
				log.actedUntil = max(log.actedUntil, Date().addingTimeInterval(lingering))
			}
		}
		return try body()
	}

	/// Re-checks `condition` each time a notification arrives or the front app changes, until
	/// it holds or the deadline passes; whether it held. Between those events it sleeps.
	func wait(until deadline: Date, _ condition: () -> Bool) -> Bool {
		signal.wait(until: deadline, condition)
	}

	/// Returns after the next notification or wake since `generation`, or at the deadline.
	func wait(since generation: UInt64, until deadline: Date) {
		signal.wait(since: generation, until: deadline)
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
	/// An observer thread, and whether every registration of its observer took: an app busy
	/// when it started leaves gaps, and its notifications are then incomplete.
	struct Started: Sendable {
		let thread: RunLoopThread
		let complete: Bool
	}

	private struct Observed: Sendable {
		let app: AppNotifications
		var thread: RunLoopThread
		var complete: Bool
		var startedAt = Date()
		let exit: any DispatchSourceProcess

		func stop() {
			exit.cancel()
			thread.stop()
		}
	}

	private static let limit = 4
	/// An app still too busy to register everything costs a start (each registration may wait
	/// out its messaging timeout), so an incomplete observer is retried at most this often.
	private static let restartInterval: TimeInterval = 2
	private let apps = OSAllocatedUnfairLock(initialState: [Int32: Observed]())
	private let starting = NSLock()
	/// Any change of the desktop: an app launching, quitting or taking the front, or a
	/// notification of any observed app. Waiting for a root to exist wakes on it.
	let desktop = ChangeSignal()

	/// Another app taking the front changes what every observed app's waiters look at: which
	/// app is frontmost, and a menu bar's geometry, which only the frontmost app has.
	init() {
		let center = NSWorkspace.shared.notificationCenter
		_ = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] _ in
			self?.wakeAll()
			self?.desktop.bump()
		}
		for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
			_ = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.desktop.bump() }
		}
	}

	private func wakeAll() {
		for observed in apps.withLock({ Array($0.values) }) { observed.app.wake() }
	}

	subscript(pid: Int32) -> AppNotifications? {
		apps.withLock { $0[pid]?.app }
	}

	/// The app's notifications, starting an observer thread for it first when there is none;
	/// nil when the app accepts no observer. Starts are serialized, so an app never gets two
	/// at once. An observer that did not register everything is replaced by a fresh one the
	/// next time the app is asked for, keeping the history recorded so far.
	func ensure(_ pid: Int32, start: (AppNotifications) -> Started?) -> AppNotifications? {
		starting.withLock {
			if let existing = apps.withLock({ $0[pid] }) {
				existing.app.touch()
				if !existing.complete, Date().timeIntervalSince(existing.startedAt) >= Self.restartInterval {
					update(existing.app) { $0.startedAt = Date() }
					if let restarted = start(existing.app) { replace(existing.app, with: restarted) }
				}
				return existing.app
			}
			let app = AppNotifications(pid: pid, desktop: desktop)
			guard let started = start(app) else { return nil }
			let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
			exit.setEventHandler { [weak self] in self?.drop(app) }
			insert(Observed(app: app, thread: started.thread, complete: started.complete, exit: exit))
			exit.resume()
			return app
		}
	}

	/// Swaps the observer thread of an app still observed; the old one stops once the new
	/// one runs, so no notification falls between them.
	private func replace(_ app: AppNotifications, with started: Started) {
		let old = update(app) { observed in
			defer { observed.thread = started.thread; observed.complete = started.complete }
			return observed.thread
		}
		(old ?? started.thread).stop()
	}

	/// Changes the record of an app still observed; nil when it is not.
	@discardableResult
	private func update<T: Sendable>(_ app: AppNotifications, _ change: @Sendable (inout Observed) -> T) -> T? {
		apps.withLock { apps in
			guard var observed = apps[app.pid], observed.app === app else { return nil }
			let result = change(&observed)
			apps[app.pid] = observed
			return result
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

	/// Starts recording the app's notifications if nothing does yet: what it announces from
	/// a look on is the history an action on it is judged against (see
	/// `AppNotifications.selfChangeLookback`).
	/// An app that accepts no observer is looked at all the same.
	func startObserving(_ pid: Int32) {
		_ = rootObservers.ensure(pid, start: startObserver)
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
	private func startObserver(for app: AppNotifications) -> RootObservers.Started? {
		let complete = Handoff(false)
		let thread = RunLoopThread.start { [self] in
			guard let made = makeObserver(for: app) else { return nil }
			complete.value = made.complete
			CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(made.observer), .commonModes)
			return made.observer
		}
		return thread.map { RootObservers.Started(thread: $0, complete: complete.value) }
	}

	/// The observer, and whether the app was answering: its window list read and no
	/// registration timed out. Nil when not one registration took.
	private func makeObserver(for app: AppNotifications) -> (observer: AXObserver, complete: Bool)? {
		let appElement = AXUIElementCreateApplication(app.pid)
		AXUIElementSetMessagingTimeout(appElement, quickMessagingTimeout)
		var observer: AXObserver?
		let createStatus = AXObserverCreate(app.pid, { _, element, notification, refcon in
			guard let refcon else { return }
			let name = notification as String
			let changed = name == kAXValueChangedNotification || name == kAXTitleChangedNotification
			Unmanaged<AppNotifications>.fromOpaque(refcon).takeUnretainedValue().record(name, element: changed ? AXElement(element: element) : nil)
		}, &observer)
		guard createStatus == .success, let observer else { return nil }
		// Unretained: the observer thread holds `app` for as long as the observer can call back.
		let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(app).toOpaque())
		let windows = axElementArrayIfPresent(appElement, attribute: kAXWindowsAttribute as CFString)
		var registered = false
		var complete = windows != nil
		for observed in [appElement] + (windows ?? []) {
			for notification in observedNotifications {
				let status = AXObserverAddNotification(observer, observed, notification as CFString, context)
				if status == .success || status == .notificationAlreadyRegistered { registered = true }
				// Busy: the same registration takes later. Any other refusal is for good.
				if status == .cannotComplete { complete = false }
			}
		}
		return registered ? (observer, complete) : nil
	}


	/// An observer that bumps `signal` when the app opens, retitles or focuses a window; nil
	/// for this process, a background-only process, or an app that takes no observer.
	func rootObserver(pid: Int32, signal: ChangeSignal) -> AXObserver? {
		guard pid != getpid(), NSRunningApplication(processIdentifier: pid)?.activationPolicy != .prohibited else { return nil }
		let appElement = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(appElement, quickMessagingTimeout)
		var observer: AXObserver?
		guard AXObserverCreate(pid, { _, _, _, refcon in
			guard let refcon else { return }
			Unmanaged<ChangeSignal>.fromOpaque(refcon).takeUnretainedValue().bump()
		}, &observer) == .success, let observer else { return nil }
		// Unretained: the desktop signal lives as long as the platform.
		let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(signal).toOpaque())
		let registered = [kAXWindowCreatedNotification, kAXTitleChangedNotification, kAXFocusedWindowChangedNotification].filter {
			[.success, .notificationAlreadyRegistered].contains(AXObserverAddNotification(observer, appElement, $0 as CFString, context))
		}
		return registered.isEmpty ? nil : observer
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
