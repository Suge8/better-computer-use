import CoreGraphics
import Foundation
import Observation

/// Main-actor playback of planned moves, consumed by the SwiftUI overlay. Each move is planned
/// once; a frame only advances the clock and reads one sample and its effects.
@Observable
@MainActor
final class AgentCursorRenderer {
	static let shared = AgentCursorRenderer(motion: CursorMotion())

	@ObservationIgnored var motion: CursorMotion
	private(set) var isAnimating = false
	@ObservationIgnored private(set) var hotspot = CGPoint(x: -200, y: -200)
	@ObservationIgnored private(set) var heading = restHeading
	@ObservationIgnored private(set) var effects = CursorEffectFrame()

	@ObservationIgnored private var trajectory: CursorTrajectory?
	@ObservationIgnored private var clicked = false
	@ObservationIgnored private var elapsed = 0.0
	@ObservationIgnored private var lastFrameTime: CFTimeInterval?
	@ObservationIgnored private var moves = 0

	init(motion: CursorMotion) {
		self.motion = motion
	}

	var isPlaced: Bool { hotspot.x > -100 }

	/// Plans a move of the hotspot from where it is now; a move in flight is replaced.
	/// `clicks` plays the click effects when the hotspot arrives.
	func moveTo(point: CGPoint, target: CGRect?, clicks: Bool, reducedMotion: Bool) {
		moves += 1
		let request = MoveRequest(from: hotspot, fromHeading: heading, to: point, target: target, seed: "bcu|\(moves)", reducedMotion: reducedMotion)
		trajectory = planMove(motion, request)
		clicked = clicks
		elapsed = 0
		lastFrameTime = nil
		isAnimating = true
	}

	func setInitialPosition(_ point: CGPoint) {
		hotspot = point
		heading = restHeading
		cancelAnimation()
	}

	func cancelAnimation() {
		trajectory = nil
		effects = CursorEffectFrame()
		lastFrameTime = nil
		isAnimating = false
	}

	func tick(now: CFTimeInterval) {
		guard isAnimating, let trajectory else { return }
		elapsed += max(0, now - (lastFrameTime ?? now))
		lastFrameTime = now
		let sample = trajectory.sample(at: elapsed)
		hotspot = sample.point
		heading = sample.heading
		let clickEnd = clicked && (trajectory.effects.ripple || trajectory.effects.squish) ? trajectory.arrival + CursorEffectTiming.click : 0
		if elapsed >= max(trajectory.linger, clickEnd) {
			cancelAnimation()
		} else {
			effects = trajectory.effectFrame(at: elapsed, clicked: clicked)
		}
	}
}
