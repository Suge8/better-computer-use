@testable import BCUPlatform
import Foundation
import Testing

// Root notifications come from one observer per app, for at most four apps; requests that
// race to observe the same app share the one observer.
struct RootObserversTests {
	@Test func concurrentRequestsForOneAppStartOneObserver() {
		let observers = RootObservers()
		let starts = Box(0)
		DispatchQueue.concurrentPerform(iterations: 32) { _ in
			_ = observers.ensure(7) { _ in
				starts.value += 1
				usleep(1_000)
				return true
			}
		}
		#expect(starts.value == 1)
	}

	@Test func aFifthAppDropsTheLeastRecentlyUsed() {
		let observers = RootObservers()
		for pid in Int32(1)...4 {
			_ = observers.ensure(pid) { _ in true }
			usleep(1_000)
		}
		_ = observers.ensure(1) { _ in Issue.record("an observed app was started again"); return true }
		_ = observers.ensure(5) { _ in true }
		#expect(observers[1] != nil)
		#expect(observers[2] == nil)
		#expect([3, 4, 5].allSatisfy { observers[$0] != nil })
	}

	@Test func anAppThatRefusesAnObserverIsNotKept() {
		let observers = RootObservers()
		#expect(observers.ensure(9) { _ in false } == nil)
		#expect(observers[9] == nil)
	}
}
