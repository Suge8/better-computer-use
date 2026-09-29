@testable import BCUPlatform
import Foundation
import Testing

// Root notifications come from one observer thread per app, for at most four apps; requests
// that race to observe the same app share the one observer. An app dropped from observation,
// by eviction or because it quit, has its thread stopped and what the thread held released.

/// Stands in for an app's observer: kept only by its thread, and signals when it is released.
private final class Kept: Sendable {
	let released: DispatchSemaphore
	init(_ released: DispatchSemaphore) { self.released = released }
	deinit { released.signal() }
}

/// An observer thread that runs until stopped; a timer far in the future keeps its run loop
/// busy, as the observer's own source does.
private func observerThread(signalling released: DispatchSemaphore = DispatchSemaphore(value: 0)) -> RunLoopThread? {
	RunLoopThread.start {
		let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
		CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
		return [timer as AnyObject, Kept(released)] as NSArray
	}
}

/// Apps to observe: running processes, since an app that is not running is dropped at once.
private func runningApps(_ count: Int) throws -> [Process] {
	try (0..<count).map { _ in
		let process = Process()
		process.executableURL = URL(filePath: "/bin/sleep")
		process.arguments = ["60"]
		try process.run()
		return process
	}
}

/// Waits for the thread's kept object to go; the bound only turns a thread that never stops
/// into a failure.
private func stopped(_ signal: DispatchSemaphore) -> Bool {
	signal.wait(timeout: .now() + 5) == .success
}

struct RootObserversTests {
	@Test func concurrentRequestsForOneAppStartOneObserver() throws {
		let app = try runningApps(1)[0]
		defer { app.terminate() }
		let pid = app.processIdentifier
		let observers = RootObservers()
		let starts = Handoff(0)
		DispatchQueue.concurrentPerform(iterations: 32) { _ in
			_ = observers.ensure(pid) { _ in
				starts.value += 1
				return observerThread()
			}
		}
		#expect(starts.value == 1)
	}

	@Test func aFifthAppDropsTheLeastRecentlyUsedAndStopsItsThread() throws {
		let apps = try runningApps(5)
		defer { apps.forEach { $0.terminate() } }
		let pids = apps.map(\.processIdentifier)
		let observers = RootObservers()
		let released = (0..<4).map { _ in DispatchSemaphore(value: 0) }
		for index in 0..<4 {
			_ = observers.ensure(pids[index]) { _ in observerThread(signalling: released[index]) }
			usleep(1_000)
		}
		_ = observers.ensure(pids[0]) { _ in Issue.record("an observed app was started again"); return nil }
		_ = observers.ensure(pids[4]) { _ in observerThread() }
		#expect(observers[pids[0]] != nil)
		#expect(observers[pids[1]] == nil)
		#expect(pids[2...].allSatisfy { observers[$0] != nil })
		#expect(stopped(released[1]), "the evicted app's observer thread kept running")
	}

	@Test func anAppThatQuitsIsDroppedAndItsThreadStopped() throws {
		let child = try runningApps(1)[0]
		let observers = RootObservers()
		let pid = child.processIdentifier
		let signal = DispatchSemaphore(value: 0)
		_ = observers.ensure(pid) { _ in observerThread(signalling: signal) }
		child.terminate()
		#expect(stopped(signal), "the quit app's observer thread kept running")
		#expect(observers[pid] == nil)
	}

	@Test func anAppThatRefusesAnObserverIsNotKept() throws {
		let app = try runningApps(1)[0]
		defer { app.terminate() }
		let observers = RootObservers()
		#expect(observers.ensure(app.processIdentifier) { _ in nil } == nil)
		#expect(observers[app.processIdentifier] == nil)
	}
}
