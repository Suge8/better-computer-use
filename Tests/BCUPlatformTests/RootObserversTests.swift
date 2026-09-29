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

/// Waits for the thread's kept object to go; the bound only turns a thread that never stops
/// into a failure.
private func stopped(_ signal: DispatchSemaphore) -> Bool {
	signal.wait(timeout: .now() + 5) == .success
}

struct RootObserversTests {
	@Test func concurrentRequestsForOneAppStartOneObserver() {
		let observers = RootObservers()
		let starts = Box(0)
		DispatchQueue.concurrentPerform(iterations: 32) { _ in
			_ = observers.ensure(7) { _ in
				starts.value += 1
				return observerThread()
			}
		}
		#expect(starts.value == 1)
	}

	@Test func aFifthAppDropsTheLeastRecentlyUsedAndStopsItsThread() {
		let observers = RootObservers()
		let released = (1...4).map { _ in DispatchSemaphore(value: 0) }
		for pid in Int32(1)...4 {
			_ = observers.ensure(pid) { _ in observerThread(signalling: released[Int(pid) - 1]) }
			usleep(1_000)
		}
		_ = observers.ensure(1) { _ in Issue.record("an observed app was started again"); return nil }
		_ = observers.ensure(5) { _ in observerThread() }
		#expect(observers[1] != nil)
		#expect(observers[2] == nil)
		#expect([3, 4, 5].allSatisfy { observers[$0] != nil })
		#expect(stopped(released[1]), "the evicted app's observer thread kept running")
	}

	@Test func anAppThatQuitsIsDroppedAndItsThreadStopped() throws {
		let child = Process()
		child.executableURL = URL(filePath: "/bin/sleep")
		child.arguments = ["60"]
		try child.run()
		let observers = RootObservers()
		let pid = child.processIdentifier
		let signal = DispatchSemaphore(value: 0)
		_ = observers.ensure(pid) { _ in observerThread(signalling: signal) }
		child.terminate()
		#expect(stopped(signal), "the quit app's observer thread kept running")
		#expect(observers[pid] == nil)
	}

	@Test func anAppThatRefusesAnObserverIsNotKept() {
		let observers = RootObservers()
		#expect(observers.ensure(9) { _ in nil } == nil)
		#expect(observers[9] == nil)
	}
}
