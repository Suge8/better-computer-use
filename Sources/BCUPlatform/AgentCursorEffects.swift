import CoreGraphics
import Foundation

/// The motion effects to paint at one moment of a move; the overlay only draws them.
struct CursorEffectFrame {
	struct Glow { let center: CGPoint, radius: Double, alpha: Double }
	struct TrailSegment { let from, to: CGPoint, width: Double, alpha: Double }
	struct Magnet { let rect: CGRect, strength: Double }
	struct Ripple { let center: CGPoint, radius: Double, width: Double, alpha: Double }

	var glow: Glow?
	/// Tail first.
	var trail: [TrailSegment] = []
	var magnet: Magnet?
	var ripple: Ripple?
	/// Scale-down of the arrow about its hotspot; 0 is none.
	var squish = 0.0
}

enum CursorEffectTiming {
	/// How long click effects play after the click lands.
	static let click = 0.55
	static let ripple = 0.52
	static let magnet = 0.7
	static let trail = 0.18
}

/// Magnet glow distance outside the target rect, points.
let magnetInflate = 6.0

extension CursorTrajectory {
	/// When the move and its trail and magnet glow are over.
	var linger: Double {
		var end = duration
		if effects.trail { end += CursorEffectTiming.trail }
		if effects.magnet, let snap { end = max(end, snap + CursorEffectTiming.magnet) }
		return end
	}

	/// The effects `t` seconds into the move; `clicked` plays the click effects from arrival on.
	func effectFrame(at t: Double, clicked: Bool) -> CursorEffectFrame {
		var frame = CursorEffectFrame()
		if effects.glow { frame.glow = glow(at: t) }
		if effects.trail { frame.trail = trail(at: t) }
		if effects.magnet { frame.magnet = magnet(at: t) }
		let age = t - arrival
		guard clicked, age >= 0, age < CursorEffectTiming.click else { return frame }
		if effects.ripple, age < CursorEffectTiming.ripple {
			let k = age / CursorEffectTiming.ripple
			frame.ripple = .init(center: end.point, radius: 8 + 44 * (1 - pow(1 - k, 3)), width: 4 * (1 - k) + 1, alpha: 0.75 * (1 - k))
		}
		if effects.squish { frame.squish = squish(age: age) }
		return frame
	}

	/// A soft glow behind the arrow's body, offset against the velocity and growing with speed.
	private func glow(at t: Double) -> CursorEffectFrame.Glow? {
		guard t < duration else { return nil }
		let velocity = velocity(at: t)
		let speed = hypot(velocity.dx, velocity.dy)
		let alpha = min(speed * 0.00014, 0.42)
		guard alpha > 0.02 else { return nil }
		let s = sample(at: t)
		let body = anchor(s.point, heading: s.heading)
		let offset = min(speed * 0.009, 18)
		return .init(
			center: CGPoint(x: body.x - velocity.dx / speed * offset, y: body.y - velocity.dy / speed * offset),
			radius: 30 * (1 + min(speed * 0.00024, 0.44)),
			alpha: alpha
		)
	}

	/// The comet trail follows the arrow's body, not its tip, so it flows out from behind the
	/// arrow; a short trail at the start and the landing fades instead of showing a stub.
	private func trail(at t: Double) -> [CursorEffectFrame.TrailSegment] {
		let steps = 26, fadeLength = 60.0, tailWidth = 2.0, headWidth = 12.0, headAlpha = 0.38
		let points = (0...steps).map { i in
			let s = sample(at: t - CursorEffectTiming.trail * (1 - Double(i) / Double(steps)))
			return anchor(s.point, heading: s.heading)
		}
		let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
		let fade = min(lengths.reduce(0, +) / fadeLength, 1)
		return lengths.indices.compactMap { i in
			guard lengths[i] > 0.3 else { return nil }
			let k = Double(i + 1) / Double(steps)
			return .init(from: points[i], to: points[i + 1], width: tailWidth + (headWidth - tailWidth) * k, alpha: headAlpha * k * k * fade)
		}
	}

	private func magnet(at t: Double) -> CursorEffectFrame.Magnet? {
		guard let snap, t >= snap, t - snap < CursorEffectTiming.magnet else { return nil }
		let rect = targetKnown ? target : CGRect(x: end.x - 12, y: end.y - 12, width: 24, height: 24)
		return .init(rect: rect, strength: 1 - (t - snap) / CursorEffectTiming.magnet)
	}

	/// Quick in while the button is down, springy out after the release.
	private func squish(age: Double) -> Double {
		let depth = 0.12, press = 0.09
		guard age >= press else { return depth * min(age / 0.05, 1) }
		let after = age - press
		return depth * max(cos(min(after / 0.22, 1) * .pi * 1.5), 0) * max(1 - after / 0.22, 0)
	}
}
