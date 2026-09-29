import AppKit
@testable import BCUPlatform
import Testing

// Waiting for an effect is driven by events: a waiter re-checks its condition when the app
// posts an accessibility notification or another app takes the front, and otherwise sleeps
// until its deadline instead of polling.

private final class Condition: Sendable {
	private let state = Handoff((holds: false, checks: 0))

	var holds: Bool {
		get { state.value.holds }
		set { state.value = (newValue, state.value.checks) }
	}

	var checks: Int { state.value.checks }

	func check() -> Bool {
		let current = state.value
		state.value = (current.holds, current.checks + 1)
		return current.holds
	}
}

/// Runs the wait on its own thread and returns its answer once it is back.
private func waiting(on app: AppNotifications, for seconds: Double, _ condition: Condition) -> () -> Bool {
	let answer = Handoff<Bool?>(nil)
	let done = DispatchSemaphore(value: 0)
	Thread.detachNewThread {
		answer.value = app.wait(until: Date().addingTimeInterval(seconds)) { condition.check() }
		done.signal()
	}
	return {
		done.wait()
		return answer.value!
	}
}

struct NotificationWaitTests {
	@Test func withoutNotificationsTheConditionIsNotPolled() {
		let condition = Condition()
		let answer = waiting(on: AppNotifications(pid: 1), for: 1, condition)
		#expect(answer() == false)
		#expect(condition.checks <= 2, "checked \(condition.checks) times without a notification")
	}

	@Test func aNotificationWakesTheWaiter() {
		let app = AppNotifications(pid: 1)
		let condition = Condition()
		let started = Date()
		let answer = waiting(on: app, for: 5, condition)
		usleep(50_000)
		condition.holds = true
		app.record("AXValueChanged")
		#expect(answer() == true)
		#expect(Date().timeIntervalSince(started) < 1)
	}

	@Test func anotherAppTakingTheFrontWakesTheWaiter() throws {
		let observers = RootObservers()
		let app = try #require(observers.ensure(getpid()) { _ in
			RunLoopThread.start {
				let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
				CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
				return timer
			}
		})
		let condition = Condition()
		let started = Date()
		let answer = waiting(on: app, for: 5, condition)
		usleep(50_000)
		condition.holds = true
		NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared)
		#expect(answer() == true)
		#expect(Date().timeIntervalSince(started) < 1)
	}
}
