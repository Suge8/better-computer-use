import CoreGraphics
import Foundation

// A move is planned once as timed samples and played back by time, so every frame rate shows
// the same motion. Generators work like the cua motion lab: milliseconds and hotspot points.

/// The arrow at rest points up and to the left.
let restHeading = Double.pi / 4
/// The arrow's body sits this far behind the hotspot along the heading; the trail and the
/// static bloom start there.
let pointerAnchorOffset = 16.0

private let sampleMs = 1000.0 / 120.0
/// Target box assumed when a move has no element rect.
private let defaultTargetSide = 24.0
private let arrivalTolerance = 1.0
private let reducedMotionMs = 120.0
private let fixedTimingMs = 1430.0

struct MotionSample {
	var t, x, y, heading: Double
	var point: CGPoint { CGPoint(x: x, y: y) }
}

/// A planned move. `arrival` is when the hotspot first reaches the target; follow-through,
/// settle and the heading's return to rest play after it.
struct CursorTrajectory {
	let samples: [MotionSample]
	let arrival: Double
	/// When the magnetic style locks on, seconds.
	let snap: Double?
	let target: CGRect
	let targetKnown: Bool
	let effects: CursorEffects

	var end: MotionSample { samples[samples.count - 1] }
	var duration: Double { end.t }

	func sample(at t: Double) -> MotionSample {
		guard t > samples[0].t else { return samples[0] }
		guard t < end.t else { return end }
		var lo = 0, hi = samples.count - 1
		while hi - lo > 1 {
			let mid = (lo + hi) / 2
			if samples[mid].t <= t { lo = mid } else { hi = mid }
		}
		let a = samples[lo], b = samples[hi]
		let f = (t - a.t) / (b.t - a.t)
		return MotionSample(t: t, x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, heading: a.heading + wrapAngle(b.heading - a.heading) * f)
	}

	/// Hotspot velocity in points per second.
	func velocity(at t: Double) -> CGVector {
		let h = 0.008
		guard t <= duration + h else { return .zero }
		let a = sample(at: t - h), b = sample(at: t + h)
		return CGVector(dx: (b.x - a.x) / (2 * h), dy: (b.y - a.y) / (2 * h))
	}
}

struct MoveRequest {
	var from: CGPoint
	var fromHeading: Double
	var to: CGPoint
	var target: CGRect?
	/// Same seed, same motion.
	var seed: String
	var reducedMotion: Bool
}

func planMove(_ motion: CursorMotion, _ request: MoveRequest) -> CursorTrajectory {
	let known = request.target.map { [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0 } ?? false
	let target = known ? request.target! : CGRect(x: request.to.x - defaultTargetSide / 2, y: request.to.y - defaultTargetSide / 2, width: defaultTargetSide, height: defaultTargetSide)
	let context = MoveContext(from: request.from, aim: request.to, target: target)
	let finish = { (raw: [Raw], snap: Double?, effects: CursorEffects, heading: HeadingMode) in
		finishMove(raw, snapMs: snap, request: request, target: target, targetKnown: known, effects: effects, heading: heading)
	}
	if request.reducedMotion {
		let raw = glide(context, path: straightPath(request.from, request.to), profile: minJerk, ms: reducedMotionMs)
		return finish(raw, nil, CursorEffects(), .fixed)
	}
	var raw: [Raw], snap: Double? = nil
	switch motion.style {
	case .classic:
		return planClassic(request, timing: motion.timing, target: target, targetKnown: known, effects: motion.effects)
	case .signatureArc:
		let profile = followThrough(minJerk, context, amount: 0.018, maxPoints: 8, at: 0.82)
		raw = arc(context, size: 0.16, flow: 0.15, profile: profile, ms: fittsMs(context, scale: 1.1))
	case .springSettle:
		let profile = spring(context, glideEnd: 0.68, amount: 0.05, maxPoints: 6, cycles: 1.3, decay: 2.6, start: 0.55)
		raw = arc(context, size: 0.12, flow: 0, profile: profile, ms: fittsMs(context, scale: 1.35))
	case .cometSwoop:
		raw = arc(context, size: 0.24, flow: 0.2, profile: inOutCubic, ms: fittsMs(context, scale: 1.15))
	case .magnetic:
		(raw, snap) = magnetic(context)
	case .adaptive:
		var rng = SeededRandom(seed: request.seed)
		raw = adaptive(context, &rng)
	}
	applyTiming(motion.timing, to: &raw, snap: &snap, context)
	return finish(raw, snap, motion.effects, motion.style == .magnetic ? .fixed : .tangent)
}

// MARK: - Generators

private struct Raw { var t, x, y: Double }

private struct MoveContext {
	let from, aim: CGPoint
	let target: CGRect
	var distance: Double { hypot(aim.x - from.x, aim.y - from.y) }
	/// The target's smaller side, at least 4 pt.
	var targetWidth: Double { max(min(target.width, target.height), 4) }
	/// The side that bends paths upward for horizontal moves.
	var side: Double { unit(from, aim).x >= 0 ? -1 : 1 }
}

/// A careful approach for small targets, a swoop for long throws, a minimum-jerk reach otherwise.
private func adaptive(_ context: MoveContext, _ rng: inout SeededRandom) -> [Raw] {
	if context.targetWidth < 16 { return preciseClick(context) }
	if context.distance > 900 { return keynoteSwoop(context, &rng) }
	return glide(context, path: bowPath(context.from, context.aim, amount: 0.02 * context.side), profile: minJerk, ms: labFittsMs(context))
}

/// The Fitts model of the arc styles, scaled per style.
private func fittsMs(_ context: MoveContext, scale: Double) -> Double {
	fittsTimingMs(distance: context.distance, width: context.targetWidth) * scale
}

private func fittsTimingMs(distance: Double, width: Double) -> Double {
	min(max(150 + 120 * log2(distance / max(width, 4) + 1), 300), 1000)
}

/// The motion lab's own Fitts helper, used by the adaptive generators.
private func labFittsMs(_ context: MoveContext) -> Double {
	min(max(50 + 150 * log2(context.distance / context.targetWidth + 1), 180), 1400)
}

private func arc(_ context: MoveContext, size: Double, flow: Double, profile: (Double) -> Double, ms: Double) -> [Raw] {
	let path = cuaPath(context.from, context.aim, startHandle: 0.3, endHandle: 0.3, arcSize: size * context.side, arcFlow: flow)
	return glide(context, path: path, profile: profile, ms: ms)
}

private func keynoteSwoop(_ context: MoveContext, _ rng: inout SeededRandom) -> [Raw] {
	let size = rng.range(0.25, 0.35)
	let ms = min(max(350 + 0.35 * context.distance, 450), 1100)
	return arc(context, size: size, flow: 0.2, profile: inOutCubic, ms: ms)
}

/// Cruise, then the final 15% at most 35% speed, no overshoot.
private func preciseClick(_ context: MoveContext) -> [Raw] {
	let finalPart = 0.15, finalSpeed = 0.35
	let shape = { (s: Double) -> Double in
		if s < 0.4 { return 0.04 + sin(Double.pi * s / 0.8) }
		if s < 1 - finalPart { return 1 - (1 - finalSpeed) * inOutSine((s - 0.4) / (0.6 - finalPart)) }
		return 0.02 + finalSpeed * max((1 - s) / finalPart, 0).squareRoot()
	}
	let path = bowPath(context.from, context.aim, amount: 0.03 * context.side)
	return speedShaped(context, path: path, shape: shape, ms: labFittsMs(context) * 1.2)
}

/// Decelerates to a 40 pt capture radius, then the target pulls it in. Also returns the
/// lock-on time in ms.
private func magnetic(_ context: MoveContext) -> ([Raw], Double?) {
	let path = bowPath(context.from, context.aim, amount: 0.04 * context.side)
	let length = path.length
	let radius = min(40, length * 0.5)
	let pull = 0.45, enterSpeed = 300.0, dt = sampleMs / 1000
	var out = [Raw(t: 0, x: context.from.x, y: context.from.y)]
	var s = 0.0, v = 0.0, t = 0.0
	var snap: Double?
	while s < length && t < 4 {
		let remaining = length - s
		if remaining > radius {
			v = min(1500, v + 7000 * dt, enterSpeed + 5.5 * (remaining - radius))
		} else {
			if snap == nil { snap = t * 1000 }
			v += 26000 * pull * (radius / max(remaining, 6)) * dt
		}
		s = min(length, s + v * dt)
		t += dt
		let q = path.at(s / length)
		out.append(Raw(t: t * 1000, x: q.x, y: q.y))
	}
	return (pinEnds(out, context), snap ?? t * 1000)
}

private func sampleTimed(ms: Double, _ position: (Double) -> CGPoint) -> [Raw] {
	let n = max(Int((ms / sampleMs).rounded(.up)), 2)
	return (0...n).map { i in
		let tau = Double(i) / Double(n)
		let p = position(tau)
		return Raw(t: tau * ms, x: p.x, y: p.y)
	}
}

private func pinEnds(_ samples: [Raw], _ context: MoveContext) -> [Raw] {
	var samples = samples
	samples[0].x = context.from.x
	samples[0].y = context.from.y
	samples[samples.count - 1].x = context.aim.x
	samples[samples.count - 1].y = context.aim.y
	return samples
}

private func glide(_ context: MoveContext, path: ArcLengthPath, profile: (Double) -> Double, ms: Double) -> [Raw] {
	pinEnds(sampleTimed(ms: ms) { path.at(profile($0)) }, context)
}

/// Integrates a speed shape v(s) along the path into a timed glide.
private func speedShaped(_ context: MoveContext, path: ArcLengthPath, shape: (Double) -> Double, ms: Double) -> [Raw] {
	let n = 600
	var times = [Double](repeating: 0, count: n + 1)
	for i in 1...n {
		times[i] = times[i - 1] + 1 / max(shape((Double(i) - 0.5) / Double(n)), 1e-3)
	}
	let total = times[n]
	return pinEnds(sampleTimed(ms: ms) { tau in
		let goal = tau * total
		var lo = 0, hi = n
		while hi - lo > 1 {
			let mid = (lo + hi) / 2
			if times[mid] < goal { lo = mid } else { hi = mid }
		}
		let f = (goal - times[lo]) / max(times[hi] - times[lo], 1e-9)
		return path.at((Double(lo) + f) / Double(n))
	}, context)
}

private func applyTiming(_ timing: CursorMotionTiming, to samples: inout [Raw], snap: inout Double?, _ context: MoveContext) {
	let total = samples[samples.count - 1].t
	let want: Double
	switch timing {
	case .native: return
	case .fixed: want = fixedTimingMs
	case .fitts:
		let last = samples[samples.count - 1]
		want = fittsTimingMs(distance: hypot(last.x - context.from.x, last.y - context.from.y), width: min(context.target.width, context.target.height))
	}
	guard total > 0 else { return }
	if samples.count >= 3 {
		for i in samples.indices { samples[i].t *= want / total }
	}
	snap = snap.map { $0 * want / total }
}

// MARK: - Heading and arrival

private enum HeadingMode { case tangent, fixed }

/// The lab's tip angle at rest, in screen space.
private let tipAngle = -0.75 * Double.pi

/// Turns lab samples into a played move: the arrow's tip leads along the direction of travel
/// once it moves fast enough, eases back to rest at the end, and arrival is the first sample
/// within a point of the target.
private func finishMove(_ raw: [Raw], snapMs: Double?, request: MoveRequest, target: CGRect, targetKnown: Bool, effects: CursorEffects, heading mode: HeadingMode) -> CursorTrajectory {
	let n = raw.count
	var rotation = wrapAngle(request.fromHeading - restHeading)
	var samples: [MotionSample] = []
	samples.reserveCapacity(n + 36)
	for i in 0..<n {
		let a = raw[max(i - 2, 0)], b = raw[min(i + 2, n - 1)]
		let dt = max((b.t - a.t) / 1000, 1e-3)
		let vx = (b.x - a.x) / dt, vy = (b.y - a.y) / dt
		let want = switch mode {
		case .tangent: wrapAngle(atan2(vy, vx) - tipAngle) * min(max((hypot(vx, vy) - 40) / 260, 0), 1)
		case .fixed: 0.0
		}
		let step = i > 0 ? (raw[i].t - raw[i - 1].t) / 1000 : 0
		rotation += wrapAngle(want - rotation) * (1 - exp(-step * 22))
		samples.append(MotionSample(t: raw[i].t / 1000, x: raw[i].x, y: raw[i].y, heading: restHeading + rotation))
	}
	let end = samples[n - 1]
	let dt = sampleMs / 1000
	var t = end.t
	for _ in 0..<36 where abs(rotation) >= 0.002 {
		t += dt
		rotation -= rotation * (1 - exp(-dt * 22))
		samples.append(MotionSample(t: t, x: end.x, y: end.y, heading: restHeading + rotation))
	}
	samples[samples.count - 1].heading = restHeading
	let arrival = samples.first { hypot($0.x - request.to.x, $0.y - request.to.y) <= arrivalTolerance }?.t ?? samples[samples.count - 1].t
	return CursorTrajectory(samples: samples, arrival: arrival, snap: snapMs.map { $0 / 1000 }, target: target, targetKnown: targetKnown, effects: effects)
}

// MARK: - Classic

/// The Dubins glide: arc–straight–arc path, a smootherstep speed envelope, then an arrival
/// spring. It is planned for the arrow's body, so its shape is the one bcu always had.
private func planClassic(_ request: MoveRequest, timing: CursorMotionTiming, target: CGRect, targetKnown: Bool, effects: CursorEffects) -> CursorTrajectory {
	let springK = 400.0, springC = 17.0, impulseShare = 0.8
	let peakSpeed = 900.0, minStartSpeed = 300.0, minEndSpeed = 200.0, turnRadius = 80.0
	let dt = sampleMs / 1000
	let start = anchor(request.from, heading: request.fromHeading)
	let goal = anchor(request.to, heading: restHeading)
	let path = DubinsPath(x0: start.x, y0: start.y, th0: request.fromHeading + .pi, x1: goal.x, y1: goal.y, th1: restHeading + .pi, radius: turnRadius)
	let length = max(path.length, 1)
	var out: [MotionSample] = []
	func push(_ t: Double, _ x: Double, _ y: Double, _ heading: Double) {
		out.append(MotionSample(t: t, x: x - cos(heading) * pointerAnchorOffset, y: y - sin(heading) * pointerAnchorOffset, heading: heading))
	}
	push(0, start.x, start.y, request.fromHeading)
	var d = 0.0, t = 0.0, speed = 0.0
	while d < length {
		let u = min(d / length, 1)
		let floor = u < 0.5 ? minStartSpeed : minEndSpeed
		speed = timing == .fixed ? length / (fixedTimingMs / 1000) : floor + (peakSpeed - floor) * 16 * u * u * (1 - u) * (1 - u)
		d += speed * dt
		t += dt
		guard d < length else { break }
		let s = path.sample(at: d)
		push(t, s.x, s.y, s.heading + .pi)
	}
	let endHeading = path.sample(at: length).heading
	push(t, goal.x, goal.y, restHeading)
	let arrival = t
	let impulse = timing == .fixed ? minEndSpeed : speed
	var ox = 0.0, oy = 0.0
	var vx = impulse * impulseShare * cos(endHeading), vy = impulse * impulseShare * sin(endHeading)
	for _ in 0..<600 {
		for _ in 0..<4 {
			vx += (-springK * ox - springC * vx) * dt / 4
			vy += (-springK * oy - springC * vy) * dt / 4
			ox += vx * dt / 4
			oy += vy * dt / 4
		}
		t += dt
		if hypot(ox, oy) < 0.3 && hypot(vx, vy) < 2 { break }
		push(t, goal.x + ox, goal.y + oy, restHeading)
	}
	push(t + dt, goal.x, goal.y, restHeading)
	out[out.count - 1].x = request.to.x
	out[out.count - 1].y = request.to.y
	var scale = 1.0
	if timing == .fitts, let total = out.last?.t, total > 0 {
		scale = fittsTimingMs(distance: hypot(request.to.x - request.from.x, request.to.y - request.from.y), width: min(target.width, target.height)) / 1000 / total
		for i in out.indices { out[i].t *= scale }
	}
	return CursorTrajectory(samples: out, arrival: arrival * scale, snap: nil, target: target, targetKnown: targetKnown, effects: effects)
}

// MARK: - Paths

/// A parametric path with an arc-length table, so speed curves act on distance. Outside 0…1
/// it extrapolates along the end tangents: that is how an overshoot leaves the path.
private struct ArcLengthPath {
	let length: Double
	private let point: (Double) -> CGPoint
	private let us: [Double]
	private let ss: [Double]
	private let p0, p1, t0, t1: CGPoint

	init(segments n: Int, _ point: @escaping (Double) -> CGPoint) {
		self.point = point
		var us = [0.0], ss = [0.0]
		var previous = point(0), total = 0.0
		for i in 1...n {
			let u = Double(i) / Double(n)
			let p = point(u)
			total += hypot(p.x - previous.x, p.y - previous.y)
			us.append(u)
			ss.append(total)
			previous = p
		}
		self.us = us
		self.ss = ss
		length = total
		p0 = point(0)
		p1 = point(1)
		t0 = unit(point(1e-3), p0)
		t1 = unit(point(1 - 1e-3), p1)
	}

	func at(_ fraction: Double) -> CGPoint {
		guard length >= 1e-9 else { return point(min(max(fraction, 0), 1)) }
		if fraction > 1 { return CGPoint(x: p1.x + t1.x * (fraction - 1) * length, y: p1.y + t1.y * (fraction - 1) * length) }
		if fraction < 0 { return CGPoint(x: p0.x - t0.x * fraction * length, y: p0.y - t0.y * fraction * length) }
		let goal = fraction * length
		var lo = 0, hi = ss.count - 1
		while hi - lo > 1 {
			let mid = (lo + hi) / 2
			if ss[mid] < goal { lo = mid } else { hi = mid }
		}
		let span = ss[hi] - ss[lo]
		return point(us[lo] + (us[hi] - us[lo]) * (goal - ss[lo]) / (span == 0 ? 1 : span))
	}
}

/// cua's cubic bezier: handles along the chord, bent sideways by `arcSize` of its length,
/// the bend peaking towards the end as `arcFlow` goes from -1 to 1.
private func cuaPath(_ a: CGPoint, _ b: CGPoint, startHandle: Double, endHandle: Double, arcSize: Double, arcFlow: Double) -> ArcLengthPath {
	let dx = b.x - a.x, dy = b.y - a.y
	let length = max(hypot(dx, dy), 1)
	let px = -dy / length, py = dx / length
	let deflection = length * arcSize
	let flow = (arcFlow + 1) / 2
	let c1d = deflection * (1 - 0.5 * flow), c2d = deflection * (1 - 0.5 * (1 - flow))
	let c1 = CGPoint(x: a.x + dx * startHandle + px * c1d, y: a.y + dy * startHandle + py * c1d)
	let c2 = CGPoint(x: b.x - dx * endHandle + px * c2d, y: b.y - dy * endHandle + py * c2d)
	return ArcLengthPath(segments: 256) { u in
		let v = 1 - u
		let (k0, k1, k2, k3) = (v * v * v, 3 * v * v * u, 3 * v * u * u, u * u * u)
		return CGPoint(x: k0 * a.x + k1 * c1.x + k2 * c2.x + k3 * b.x, y: k0 * a.y + k1 * c1.y + k2 * c2.y + k3 * b.y)
	}
}

/// A gentle quadratic bow; `amount` is the apex offset as a fraction of the distance.
private func bowPath(_ a: CGPoint, _ b: CGPoint, amount: Double) -> ArcLengthPath {
	let d = hypot(b.x - a.x, b.y - a.y)
	let u = unit(a, b)
	let c = CGPoint(x: (a.x + b.x) / 2 - u.y * amount * d, y: (a.y + b.y) / 2 + u.x * amount * d)
	return ArcLengthPath(segments: 256) { t in
		let v = 1 - t
		return CGPoint(x: v * v * a.x + 2 * v * t * c.x + t * t * b.x, y: v * v * a.y + 2 * v * t * c.y + t * t * b.y)
	}
}

private func straightPath(_ a: CGPoint, _ b: CGPoint) -> ArcLengthPath {
	ArcLengthPath(segments: 8) { u in CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u) }
}

private func unit(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
	let d = hypot(b.x - a.x, b.y - a.y)
	let length = d == 0 ? 1 : d
	return CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
}

// MARK: - Speed curves

/// Minimum jerk: the speed profile of a relaxed human reach.
private func minJerk(_ t: Double) -> Double { t * t * t * (10 - 15 * t + 6 * t * t) }
private func smootherstep(_ t: Double) -> Double { t * t * t * (t * (6 * t - 15) + 10) }
private func inOutCubic(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
private func inOutSine(_ t: Double) -> Double { 0.5 - 0.5 * cos(Double.pi * t) }

/// `base` plus a smooth bump peaking at `at` that pushes past the end, then settles back.
private func followThrough(_ base: @escaping (Double) -> Double, _ context: MoveContext, amount: Double, maxPoints: Double, at: Double) -> (Double) -> Double {
	let over = min(amount, maxPoints / max(context.distance, 1))
	let a = max(at * 10, 1.5), b = max((1 - at) * 10, 1.5)
	let peak = pow(a / (a + b), a) * pow(b / (a + b), b)
	return { tau in base(tau) + over * pow(tau, a) * pow(1 - tau, b) / peak }
}

/// Reaches the target by `glideEnd`, then wobbles around it from `start` on.
private func spring(_ context: MoveContext, glideEnd: Double, amount: Double, maxPoints: Double, cycles: Double, decay: Double, start: Double) -> (Double) -> Double {
	let amplitude = min(amount, maxPoints / max(context.distance, 1))
	let norm = max(exp(-decay * 0.12) * 0.77, 1e-6)
	return { tau in
		let glide = minJerk(min(tau / glideEnd, 1))
		guard tau > start else { return glide }
		let u = (tau - start) / (1 - start)
		let wobble = amplitude * smootherstep(min(u / 0.18, 1)) * exp(-decay * u) * sin(2 * Double.pi * cycles * u) * (1 - u) * (1 - u)
		return glide + wobble / norm
	}
}

// MARK: - Geometry and randomness

/// JavaScript's `a % TAU` wrapped into (-π, π], like the motion lab.
func wrapAngle(_ a: Double) -> Double {
	let tau = 2 * Double.pi
	var r = a.truncatingRemainder(dividingBy: tau)
	if r > .pi { r -= tau }
	if r < -.pi { r += tau }
	return r
}

/// The arrow's body point for a hotspot at `heading`.
func anchor(_ hotspot: CGPoint, heading: Double) -> CGPoint {
	CGPoint(x: hotspot.x + cos(heading) * pointerAnchorOffset, y: hotspot.y + sin(heading) * pointerAnchorOffset)
}

/// mulberry32 seeded by FNV-1a over UTF-16 code units, bit-identical to the motion lab's rng.js.
private struct SeededRandom {
	private var state: UInt32

	init(seed: String) {
		var hash: UInt32 = 0x811C_9DC5
		for unit in seed.utf16 {
			hash ^= UInt32(unit)
			hash = hash &* 0x0100_0193
		}
		state = hash == 0 ? 1 : hash
	}

	mutating func range(_ lo: Double, _ hi: Double) -> Double {
		state = state &+ 0x6D2B_79F5
		var t = state
		t = (t ^ (t >> 15)) &* (t | 1)
		t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
		return lo + (hi - lo) * Double(t ^ (t >> 14)) / 4_294_967_296
	}
}
