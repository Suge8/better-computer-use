import Foundation

/// The `classic` glide's path: the shortest arc–straight–arc route between two headings with a
/// minimum turning radius, or a straight line when no Dubins word fits.
struct DubinsPath {
	struct State { let x, y, heading: Double }

	private enum Kind { case dubins(t: Double, p: Double, q: Double, types: [Character]), linear }

	let length: Double
	private let kind: Kind
	private let x0, y0, th0, x1, y1, th1, radius: Double

	init(x0: Double, y0: Double, th0: Double, x1: Double, y1: Double, th1: Double, radius: Double) {
		self.x0 = x0
		self.y0 = y0
		self.th0 = th0
		self.x1 = x1
		self.y1 = y1
		self.th1 = th1
		self.radius = radius
		if let best = Self.solve(dx: x1 - x0, dy: y1 - y0, th0: th0, th1: th1, radius: radius) {
			kind = .dubins(t: best.t, p: best.p, q: best.q, types: best.types)
			length = best.length * radius
		} else {
			kind = .linear
			length = max(1, hypot(x1 - x0, y1 - y0))
		}
	}

	func sample(at distance: Double) -> State {
		switch kind {
		case .linear: sampleLinear(distance)
		case .dubins(let t, let p, let q, let types): sampleDubins(distance, segments: [t * radius, p * radius, q * radius], types: types)
		}
	}

	private func sampleLinear(_ s: Double) -> State {
		let u = max(0, min(1, s / length))
		var diff = th1 - th0
		while diff > .pi { diff -= 2 * .pi }
		while diff < -.pi { diff += 2 * .pi }
		return State(x: x0 + (x1 - x0) * u, y: y0 + (y1 - y0) * u, heading: th0 + diff * u)
	}

	private func sampleDubins(_ distance: Double, segments: [Double], types: [Character]) -> State {
		var x = x0, y = y0, th = th0
		var remaining = max(0, min(distance, segments.reduce(0, +)))
		for (length, type) in zip(segments, types) {
			let step = min(remaining, length)
			if type == "S" {
				x += cos(th) * step
				y += sin(th) * step
			} else {
				let turn = step / radius * (type == "L" ? 1 : -1)
				let side: Double = type == "L" ? .pi / 2 : -.pi / 2
				let cx = x + cos(th + side) * radius, cy = y + sin(th + side) * radius
				let angle = atan2(y - cy, x - cx)
				x = cx + cos(angle + turn) * radius
				y = cy + sin(angle + turn) * radius
				th += turn
			}
			remaining -= step
			if remaining <= 0 { break }
		}
		return State(x: x, y: y, heading: th)
	}

	private struct Solution {
		let t, p, q: Double
		let types: [Character]
		var length: Double { t + p + q }
	}

	private static func solve(dx: Double, dy: Double, th0: Double, th1: Double, radius: Double) -> Solution? {
		let distance = hypot(dx, dy)
		guard distance > 0.5 else { return nil }
		let d = distance / radius, theta = mod2pi(atan2(dy, dx))
		let a = mod2pi(th0 - theta), b = mod2pi(th1 - theta)
		return [lsl, rsr, lsr, rsl, rlr, lrl]
			.compactMap { $0(d, a, b) }
			.filter { $0.length.isFinite && $0.length >= 0 }
			.min { $0.length < $1.length }
	}

	private static func mod2pi(_ x: Double) -> Double {
		let tau = 2 * Double.pi
		let r = x - tau * floor(x / tau)
		return r < 0 ? r + tau : r
	}

	private static func lsl(_ d: Double, _ a: Double, _ b: Double) -> Solution? {
		let tmp0 = d + sin(a) - sin(b)
		let p2 = 2 + d * d - 2 * cos(a - b) + 2 * d * (sin(a) - sin(b))
		guard p2 >= 0 else { return nil }
		let tmp1 = atan2(cos(b) - cos(a), tmp0)
		return Solution(t: mod2pi(-a + tmp1), p: sqrt(p2), q: mod2pi(b - tmp1), types: ["L", "S", "L"])
	}

	private static func rsr(_ d: Double, _ a: Double, _ b: Double) -> Solution? {
		let tmp0 = d - sin(a) + sin(b)
		let p2 = 2 + d * d - 2 * cos(a - b) + 2 * d * (sin(b) - sin(a))
		guard p2 >= 0 else { return nil }
		let tmp1 = atan2(cos(a) - cos(b), tmp0)
		return Solution(t: mod2pi(a - tmp1), p: sqrt(p2), q: mod2pi(-b + tmp1), types: ["R", "S", "R"])
	}

	private static func lsr(_ d: Double, _ a: Double, _ b: Double) -> Solution? {
		let p2 = -2 + d * d + 2 * cos(a - b) + 2 * d * (sin(a) + sin(b))
		guard p2 >= 0 else { return nil }
		let p = sqrt(p2)
		let tmp1 = atan2(-cos(a) - cos(b), d + sin(a) + sin(b)) - atan2(-2, p)
		return Solution(t: mod2pi(-a + tmp1), p: p, q: mod2pi(-mod2pi(b) + tmp1), types: ["L", "S", "R"])
	}

	private static func rsl(_ d: Double, _ a: Double, _ b: Double) -> Solution? {
		let p2 = d * d - 2 + 2 * cos(a - b) - 2 * d * (sin(a) + sin(b))
		guard p2 >= 0 else { return nil }
		let p = sqrt(p2)
		let tmp1 = atan2(cos(a) + cos(b), d - sin(a) - sin(b)) - atan2(2, p)
		return Solution(t: mod2pi(a - tmp1), p: p, q: mod2pi(b - tmp1), types: ["R", "S", "L"])
	}

	private static func rlr(_ d: Double, _ a: Double, _ b: Double) -> Solution? {
		let tmp = (6 - d * d + 2 * cos(a - b) + 2 * d * (sin(a) - sin(b))) / 8
		guard abs(tmp) <= 1 else { return nil }
		let p = mod2pi(2 * .pi - acos(tmp))
		let t = mod2pi(a - atan2(cos(a) - cos(b), d - sin(a) + sin(b)) + p / 2)
		return Solution(t: t, p: p, q: mod2pi(a - b - t + p), types: ["R", "L", "R"])
	}

	private static func lrl(_ d: Double, _ a: Double, _ b: Double) -> Solution? {
		let tmp = (6 - d * d + 2 * cos(a - b) + 2 * d * (sin(b) - sin(a))) / 8
		guard abs(tmp) <= 1 else { return nil }
		let p = mod2pi(2 * .pi - acos(tmp))
		let t = mod2pi(-a + atan2(-cos(a) + cos(b), d + sin(a) - sin(b)) + p / 2)
		return Solution(t: t, p: p, q: mod2pi(mod2pi(b) - a - t + p), types: ["L", "R", "L"])
	}
}
