import AppKit
@testable import BCUPlatform
import CoreGraphics
import Testing

// Every motion style and timing lands the cursor's hotspot on the latest target and then
// goes idle; reduced motion is a short straight glide. The overlay window lives only between
// an action and the idle timeout that belongs to that action.
@MainActor
struct AgentCursorTests {
	@Test(arguments: CursorMotionStyle.allCases, CursorMotionTiming.allCases)
	func motionLandsOnTheLatestTargetAndSettles(style: CursorMotionStyle, timing: CursorMotionTiming) {
		let renderer = AgentCursorRenderer(), motion = CursorMotion(style: style, timing: timing)
		renderer.setInitialPosition(CGPoint(x: 100, y: 100))
		#expect(!renderer.isAnimating, "renderer should start idle")

		var now: CFTimeInterval = 0
		renderer.moveTo(point: CGPoint(x: 300, y: 300), target: nil, motion: motion, clicks: true, reducedMotion: false)
		for _ in 0..<12 {
			now += 1.0 / 120.0
			renderer.tick(now: now)
		}
		let latest = CGPoint(x: 900, y: 700)
		renderer.moveTo(point: latest, target: CGRect(x: 880, y: 690, width: 40, height: 20), motion: motion, clicks: true, reducedMotion: false)
		#expect(renderer.isAnimating, "a move should start rendering")
		for _ in 0..<12_000 where renderer.isAnimating {
			now += 1.0 / 120.0
			renderer.tick(now: now)
		}
		#expect(!renderer.isAnimating, "\(style)/\(timing) should go idle after the move and its effects")
		#expect(hypot(renderer.hotspot.x - latest.x, renderer.hotspot.y - latest.y) < 0.001, "\(style)/\(timing) should land the hotspot on the latest target, not \(renderer.hotspot)")
	}

	@Test func reducedMotionIsAShortStraightGlide() {
		let renderer = AgentCursorRenderer()
		let start = CGPoint(x: 100, y: 100), end = CGPoint(x: 900, y: 500)
		renderer.setInitialPosition(start)
		renderer.moveTo(point: end, target: nil, motion: CursorMotion(style: .cometSwoop), clicks: true, reducedMotion: true)
		var now: CFTimeInterval = 0
		for _ in 0..<16 where renderer.isAnimating {
			now += 1.0 / 120.0
			renderer.tick(now: now)
			let p = renderer.hotspot
			let cross = (end.x - start.x) * (p.y - start.y) - (end.y - start.y) * (p.x - start.x)
			#expect(abs(cross) / hypot(end.x - start.x, end.y - start.y) < 0.5, "reduced motion should stay on the straight line, not pass \(p)")
		}
		#expect(!renderer.isAnimating, "reduced motion should finish within about 120 ms")
		#expect(renderer.hotspot == end)
	}

	@Test func overlayHidesOnlyOnItsOwnIdleTimeout() throws {
		let application = NSApplication.shared
		let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
		let scheduler = ManualIdleHideScheduler()
		let cursor = AgentCursor(scheduleIdleHide: scheduler.schedule)

		cursor.animate(to: CGPoint(x: 300, y: 300), above: 0, motion: CursorMotion())
		let firstWindow = try #require(application.windows.first { !existingWindows.contains(ObjectIdentifier($0)) && $0.isVisible }, "first action should create a visible overlay")

		cursor.animate(to: CGPoint(x: 500, y: 500), above: 0, motion: CursorMotion())
		#expect(scheduler.count == 2, "each action should replace the idle timeout")

		scheduler.fire(0)
		#expect(firstWindow.isVisible, "a stale timeout should not hide the current overlay")
		#expect(firstWindow.contentView != nil, "a stale timeout should not release the current view")

		scheduler.fire(1)
		#expect(!AgentCursorRenderer.shared.isAnimating, "the current timeout should stop rendering")
		#expect(!firstWindow.isVisible, "the current timeout should hide the overlay")
		#expect(firstWindow.contentView == nil, "the current timeout should release the view tree")

		cursor.animate(to: CGPoint(x: 700, y: 700), above: 0, motion: CursorMotion())
		let recreatedWindow = try #require(application.windows.first { !existingWindows.contains(ObjectIdentifier($0)) && $0 !== firstWindow && $0.isVisible }, "a later action should recreate the overlay")

		scheduler.fire(2)
		#expect(!recreatedWindow.isVisible, "the recreated overlay should retain the idle lifecycle")
		#expect(recreatedWindow.contentView == nil, "the recreated overlay should release its view tree")
	}
}

@MainActor
private final class ManualIdleHideScheduler {
	private var actions: [@MainActor () -> Void] = []

	var count: Int { actions.count }

	func schedule(_ action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
		actions.append(action)
		return Task {}
	}

	func fire(_ index: Int) {
		actions[index]()
	}
}
